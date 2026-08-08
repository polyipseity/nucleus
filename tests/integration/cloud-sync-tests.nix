# tests/integration/cloud-sync-tests.nix — Schema and invariant tests for cloud-drives.nix.

let
  inherit (import ../lib.nix) assert' containsRegex;

  lib = import <nixpkgs/lib>;
  repoRoot = ../..;
  usersMacBook = import ../../src/modules/lib/users-registry.nix {
    inherit lib repoRoot;
    hostName = "MacBook";
  };
  usersWindows = import ../../src/modules/lib/users-registry.nix {
    inherit lib repoRoot;
    hostName = "Windows";
  };
  polyipseityMacBook = usersMacBook.polyipseity;
  polyipseityWindows = usersWindows.polyipseity;
  posixUsersText = builtins.toJSON polyipseityMacBook;
  windowsUsersText = builtins.toJSON polyipseityWindows;
  defaultCloudDrivesText = builtins.readFile ../../src/users/default/cloud-drives.json;

  moduleText = builtins.readFile ../../src/modules/cloud-drives.nix;
  flakeText = builtins.readFile ../../src/flake.nix;
  shellScriptText = builtins.readFile ../../scripts/cloud-setup.sh;
  pwshScriptText = builtins.readFile ../../scripts/cloud-setup.ps1;
  replicaSyncShellText = builtins.readFile ../../scripts/replica-sync.sh;
  replicaSyncPwshText = builtins.readFile ../../scripts/replica-sync.ps1;
  replicaResetShellText = builtins.readFile ../../scripts/replica-reset.sh;
  replicaResetPwshText = builtins.readFile ../../scripts/replica-reset.ps1;
  applyScriptText = builtins.readFile ../../src/scripts/apply.sh;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsCloudDriveModuleText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-CloudDriveCatalog.ps1;
  # Shared shell-parity profile: single source consumed by pwsh.nix (POSIX,
  # eval-time embed) and Sync-ShellProfile.ps1 (Windows, runtime read-back).
  shellProfileText = builtins.readFile ../../src/scripts/shell/profile.ps1;
  windowsReplicaModuleText = builtins.readFile ../../src/hosts/Windows/modules/system/Invoke-ReplicaSync.ps1;
  windowsReplicaResetModuleText = builtins.readFile ../../src/hosts/Windows/modules/system/Invoke-ReplicaReset.ps1;
  windowsReplicaScheduleModuleText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-ReplicaSyncScheduledTask.ps1;
  replicaGcConfigText = builtins.readFile ../../src/users/default/cloud-drives.json;
  homeNixText = builtins.readFile ../../src/modules/home.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  finderSidebarText = builtins.readFile ../../src/modules/macos/finder-sidebar.nix;
  macbookActivationText = builtins.readFile ../../src/hosts/MacBook/activation.nix;
  macbookCloudOverrideText = builtins.readFile ../../src/hosts/MacBook/cloud-drives.nix;
  macbookHomebrewText = builtins.readFile ../../src/hosts/MacBook/homebrew.nix;

  # Test 1: Module defines both mounts and replicas option lists
  test_options_exist = assert' (
    containsRegex "options\\.nucleus\\.cloudDrives = \\{" moduleText
    && containsRegex "mounts = lib\\.mkOption" moduleText
    && containsRegex "replicas = lib\\.mkOption" moduleText
  ) "cloud-drives module must declare nucleus.cloudDrives options block with mounts and replicas";

  # Test 2: Mounts use a listOf submodule type
  test_mounts_are_list = assert' (containsRegex "type = lib\.types\.listOf mountSubmodule;" moduleText) "nucleus.cloudDrives.mounts must be typed as listOf mountSubmodule";

  # Test 3: Replicas use a listOf submodule type
  test_replicas_are_list = assert' (containsRegex "type = lib\.types\.listOf replicaSubmodule;" moduleText) "nucleus.cloudDrives.replicas must be typed as listOf replicaSubmodule";

  # Test 4: Replica enable option defaults to false (opt-in)
  test_replica_enable_defaults_false = assert' (containsRegex "default = false" moduleText) "replica enable option must default to false (replicas are opt-in)";

  # Test 5: Mount enable option defaults to true
  test_mount_enable_defaults_true = assert' (containsRegex "default = true" moduleText) "mount enable option must default to true";

  # Test 6: Provider enum includes the three expected providers
  test_provider_enum_values = assert' (
    containsRegex "\"GoogleDrive\"" moduleText
    && containsRegex "\"iCloud\"" moduleText
    && containsRegex "\"OneDrive\"" moduleText
  ) "provider enum must include GoogleDrive, iCloud, and OneDrive";

  # Test 7: Module reads user config from the users registry
  test_reads_user_config = assert' (
    containsRegex "currentUsername" moduleText && containsRegex "cloudDrives.*or" moduleText
  ) "module must read per-user config from users.\${currentUsername}.cloudDrives";

  # Test 8: iCloud does not rely on native brctl-only logic
  test_icloud_not_brctl_only = assert' (
    !containsRegex "brctl download" moduleText
  ) "cloud-drives module should not require native brctl iCloud-only behavior";

  # Test 9: rclone is conditionally added to home packages
  test_rclone_package_conditional = assert' (
    containsRegex "pkgs\.rclone" moduleText && containsRegex "hasRcloneProvider" moduleText
  ) "rclone package should only be installed when rclone-backed providers are configured";

  # Test 10: cloud-drives-setup activation is defined
  test_setup_activation_exists = assert' (containsRegex "cloud-drives-setup" moduleText) "cloud-drives-setup activation must be defined for directory creation";

  # Test 11: cloudDrivesICloudRefresh activation is not required in rclone-first design
  test_no_icloud_refresh_activation = assert' (
    !containsRegex "cloudDrivesICloudRefresh" moduleText
  ) "cloudDrivesICloudRefresh activation should not exist in rclone-first cloud-drives module";

  # Test 12: macOS LaunchAgents are defined for rclone mounts
  test_macos_launchd_agents = assert' (containsRegex "launchd\.agents" moduleText) "module must define macOS LaunchAgents for rclone-backed mounts";

  # Test 13: NixOS systemd services are defined for rclone mounts
  test_nixos_systemd_services = assert' (containsRegex "systemd\.user\.services" moduleText) "module must define NixOS systemd user services for rclone-backed mounts";

  # Test 14: Module handles multiple mounts per provider (list-based schema)
  test_list_schema_allows_multiple = assert' (
    containsRegex "listOf mountSubmodule" moduleText
    && containsRegex "listOf replicaSubmodule" moduleText
  ) "schema must be list-based to allow multiple mounts/replicas per provider";

  # Test 15: iCloud service choice is first-class config in the shared schema
  test_icloud_service_option_exists = assert' (
    containsRegex "iCloudService = lib\\.mkOption" moduleText
    && containsRegex ''"drive"'' moduleText
    && containsRegex ''"photos"'' moduleText
  ) "cloud-drives module must expose an iCloud service option with drive/photos values";

  # Test 16: iCloud mounts pass the selected service explicitly to rclone
  test_icloud_mounts_pass_service = assert' (
    containsRegex "--iclouddrive-service" moduleText && containsRegex "mount\\.iCloudService" moduleText
  ) "cloud-drives mounts must pass --iclouddrive-service from user config";

  # Test 17: Both user registries pin the current iCloud entries to drive
  test_user_registries_define_icloud_service = assert' (
    containsRegex ''"iCloudService":"drive"'' posixUsersText
    && containsRegex ''"iCloudService":"drive"'' windowsUsersText
  ) "POSIX and Windows user registries must define the current iCloud service explicitly";

  # Test 18: cloud-setup app ships jq so the shell helper can read src/users/
  test_cloud_setup_runtime_has_jq = assert' (
    containsRegex "mkCloudSetupApp" flakeText && containsRegex "pkgs\\.jq" flakeText
  ) "cloud-setup app runtime must include jq for user-config lookup";

  # Test 19: cloud-setup scripts pass the configured iCloud service to create
  test_cloud_setup_passes_icloud_service = assert' (
    containsRegex "resolve_icloud_service_for_remote" shellScriptText
    && containsRegex "service" shellScriptText
    && containsRegex "Resolve-ICloudServiceForRemote" pwshScriptText
    && containsRegex "service.*iCloudService.*--all" pwshScriptText
  ) "cloud-setup scripts must preselect the configured iCloud service during remote creation";

  # Test 20: home.nix declares nucleus.rclone options for configPassEnabled and configPassSecretPath
  test_rclone_options_in_home_nix =
    assert'
      (
        containsRegex "nucleus\.rclone" homeNixText
        && containsRegex "configPassEnabled" homeNixText
        && containsRegex "configPassSecretPath" homeNixText
      )
      "home.nix must declare nucleus.rclone.configPassEnabled and nucleus.rclone.configPassSecretPath options";

  # Test 21: cloud-drives.nix emits --password-command when configPassEnabled is set
  test_cloud_drives_password_command =
    assert'
      (containsRegex "password-command" moduleText && containsRegex "configPassEnabled" moduleText)
      "cloud-drives.nix must add --password-command to mount args when nucleus.rclone.configPassEnabled is true";

  # Test 22: Both cloud-setup scripts export RCLONE_CONFIG_PASS before remote creation
  # (shell.nix previously handled this; now each script manages it independently.)
  test_cloud_setup_exports_rclone_pass =
    assert'
      (
        containsRegex "RCLONE_CONFIG_PASS" shellScriptText
        && containsRegex "rclone-config-pass" shellScriptText
        && containsRegex "RCLONE_CONFIG_PASS" pwshScriptText
        && containsRegex "rclone-config-pass" pwshScriptText
      )
      "cloud-setup scripts must export RCLONE_CONFIG_PASS from the materialized secret before rclone config create";

  # Test 24: Both cloud-setup scripts validate credentials with root-only listings
  test_cloud_setup_uses_root_only_listing = assert' (
    containsRegex "rclone lsd" shellScriptText
    && containsRegex "root-only listings" shellScriptText
    && containsRegex "rclone lsd" pwshScriptText
  ) "cloud-setup scripts must use root-only directory listings for credential validation";

  # Test 25: Finder sidebar is managed automatically via mysides with deterministic ordering
  test_finder_sidebar_automatic_strategy =
    assert'
      (
        containsRegex "pkgs\\.mysides" macosText
        && containsRegex "configure-finder-sidebar" macosText
        && containsRegex "mysides}/bin/mysides" macosText
        && containsRegex "macos-configure-finder-sidebar" macosText
        && containsRegex "import \\./macos/finder-sidebar" macosText
        && containsRegex "finderSidebar\\.finderSidebar" macosText
        && containsRegex "finderSidebarManagedFavorites" finderSidebarText
        && containsRegex "uriEncode" finderSidebarText
        && containsRegex "mysides" finderSidebarText
        && !containsRegex "finder-sidebar-repair-v2\\.done" macosText
        && !containsRegex "add favorites manually" macosText
        && !containsRegex "FavoriteItems\\.sfl4" macosText
        && !containsRegex "osascript -l JavaScript" macosText
      )
      "Finder sidebar must be configured automatically via mysides with the exact managed favorites order";

  # Test 26: macOS activation no longer pre-creates /Volumes cloud mountpoints
  test_cloud_mounts_prepare_volumes = assert' (
    !containsRegex "/Volumes/nucleus-cloud-" macbookActivationText
  ) "macOS activation should not manage /Volumes cloud mountpoints for direct-path FSKit mounts";

  # Test 27: macOS cloud mounts still force FSKit backend but no /Volumes symlink flow
  test_cloud_mounts_use_fskit_backend = assert' (
    containsRegex "backend=fskit" moduleText
    && !containsRegex "ensure_cloud_mount_link" moduleText
    && !containsRegex "/Volumes/nucleus-cloud-" moduleText
  ) "macOS cloud mounts must pass the FSKit mount-time option without the /Volumes symlink flow";

  # Test 28: Both cloud-setup scripts recreate remotes whose credentials are stale
  test_cloud_setup_recreates_stale_remotes = assert' (
    containsRegex "stale" shellScriptText
    && containsRegex "rclone config delete" shellScriptText
    && containsRegex "stale" pwshScriptText
    && containsRegex "rclone config delete" pwshScriptText
  ) "cloud-setup scripts must recreate remotes with stale or invalid credentials";

  # Test 30: macOS host package selection uses fuse-t and no longer pins macfuse
  test_macos_uses_fuse_t = assert' (
    containsRegex ''"fuse-t"'' macbookHomebrewText && !containsRegex ''"macfuse"'' macbookHomebrewText
  ) "macOS Homebrew packages must use fuse-t instead of macfuse for cloud mounts";

  # Test 31: cloud-drives preserves GoogleDrive remote id while exposing a human-readable name
  test_google_drive_name = assert' (
    containsRegex ''"id": "GoogleDrive"'' defaultCloudDrivesText
    && containsRegex ''"remoteName": "GoogleDrive"'' defaultCloudDrivesText
    && containsRegex ''"name": "Google Drive"'' defaultCloudDrivesText
  ) "GoogleDrive mount must keep remoteName=GoogleDrive while setting name=Google Drive";

  # Test 32: cloud-drives keeps iCloud replica declared but disabled by default
  test_icloud_replica_disabled =
    let
      icloudReplica = builtins.head (
        builtins.filter (replica: (replica.id or "") == "iCloud") polyipseityMacBook.cloudDrives.replicas
      );
    in
    assert' (
      icloudReplica.enable == false
      && icloudReplica.localPath == "clouds/iCloudReplica"
      && icloudReplica.direction == "pull"
    ) "iCloud replica entry must remain declared with enable=false by default";

  # Test 33: flake exports nucleus-replica-sync command
  test_flake_has_replica_command = assert' (
    containsRegex "nucleus-replica-sync" flakeText && containsRegex ''name = "replica-sync"'' flakeText
  ) "flake.nix must expose nucleus-replica-sync in nucleusApps";

  # Test 34: flake exposes replica-sync app wired to scripts/replica-sync.sh
  test_flake_has_replica_app = assert' (
    containsRegex "mkReplicaSyncApp" flakeText
    && containsRegex "replica-sync = mkReplicaSyncApp" flakeText
    && containsRegex "replica-sync" flakeText
  ) "flake apps must include replica-sync on supported systems";

  # Test 35: apply script keeps replica sync as an opt-in post-apply step
  test_apply_runs_replica_sync = assert' (
    containsRegex "run_replica_sync" applyScriptText
    && containsRegex "replica_sync=false" applyScriptText
    && containsRegex "--replica-sync" applyScriptText
    && containsRegex "default; pass --replica-sync" applyScriptText
    && containsRegex "scripts/replica-sync\\.sh" applyScriptText
  ) "apply flow must keep replica sync opt-in with an explicit post-apply hook";

  # Test 36: macOS Finder sidebar setup creates only canonical local directories and excludes cloud mount subpaths
  test_finder_sidebar_paths_created = assert' (
    containsRegex "mkdir -p" macosText
    && containsRegex "homeDirectory\}/Desktop" finderSidebarText
    && containsRegex "homeDirectory\}/dev" finderSidebarText
    && !containsRegex "finder-sidebar-repair-v2\\.done" macosText
  ) "macOS setup must create Finder sidebar path directories";

  # Test 37: macOS replica runner must skip the iCloud replica entry to avoid native-path permission churn
  test_macos_skips_icloud_replica = assert' (
    containsRegex ''"[$]host"'' replicaSyncShellText
    && containsRegex ''"MacBook"'' replicaSyncShellText
    && containsRegex ''"[$]provider" = "iCloud"'' replicaSyncShellText
    && containsRegex ''"[$]id" = "iCloud"'' replicaSyncShellText
    && containsRegex "ensure_macos_icloud_replica_symlink" replicaSyncShellText
    && containsRegex "Library/Mobile Documents" replicaSyncShellText
    && containsRegex "native iCloud handles sync" replicaSyncShellText
  ) "replica-sync.sh must skip iCloud replica on macOS";

  # Test 38: Windows parity includes a replica sync module and scripts entrypoint
  test_windows_replica_sync_entrypoints = assert' (
    containsRegex "function Invoke-ReplicaSync" windowsReplicaModuleText
    && (
      containsRegex "Load-UserRegistry.ps1" windowsReplicaModuleText
      || containsRegex "src\\\\users" windowsReplicaModuleText
    )
    && containsRegex "Invoke-ReplicaSync" replicaSyncPwshText
  ) "Windows must include Invoke-ReplicaSync module and scripts/replica-sync.ps1 wrapper";

  # Test 39: Windows apply flow has opt-in post-apply replica sync hook
  test_windows_apply_replica_hook = assert' (
    containsRegex "ReplicaSync" windowsApplyText
    && containsRegex "Invoke-ReplicaSync" windowsApplyText
    && containsRegex "default; pass -ReplicaSync" windowsApplyText
    && containsRegex "post-apply replica sync" windowsApplyText
  ) "Windows apply flow must keep replica sync as an explicit opt-in post-step";

  # Test 40: Windows shell profile exports nucleus-replica-sync command parity
  test_windows_shell_replica_command = assert' (
    containsRegex "function nucleus-replica-sync" shellProfileText
    && containsRegex ''scripts\\replica-sync\.ps1'' shellProfileText
  ) "Windows shell profile must expose nucleus-replica-sync";

  # Test 41: OneDrive replica runners must exclude Personal Vault on both platforms
  test_onedrive_personal_vault_excluded = assert' (
    containsRegex "build_onedrive_root_filter_file" replicaSyncShellText
    && containsRegex "blockedRoots" replicaGcConfigText
    && containsRegex "skipping inaccessible OneDrive root entry" replicaSyncShellText
    && containsRegex "--disable ListR" replicaSyncShellText
    && containsRegex "--dirs-only --disable ListR --log-level ERROR" replicaSyncShellText
    && containsRegex "--timeout 30s --contimeout 10s" replicaSyncShellText
    && containsRegex "--max-duration 1m" replicaSyncShellText
    && containsRegex "Get-ReplicaGcConfig" windowsReplicaModuleText
    && containsRegex "remoteExcludes" windowsReplicaModuleText
    && containsRegex "BlockedRoots" windowsReplicaModuleText
    && containsRegex "Get-OneDriveRootFilterFile" windowsReplicaModuleText
    && containsRegex "skipping inaccessible OneDrive root entry" windowsReplicaModuleText
    && containsRegex "--disable.*ListR" windowsReplicaModuleText
    && containsRegex "--timeout.*30s" windowsReplicaModuleText
    && containsRegex "--contimeout.*10s" windowsReplicaModuleText
    && containsRegex "--max-duration.*1m" windowsReplicaModuleText
  ) "Replica sync runners must exclude OneDrive Personal Vault to avoid invalidResourceId failures";

  # Test 42: iCloudReplica exception is macOS-only; Windows keeps managed real directories
  test_icloud_replica_platform_invariant =
    assert'
      (
        containsRegex "Library/Mobile Documents" macosText
        && containsRegex "clouds/iCloudReplica" moduleText
        && containsRegex "ReparsePoint" windowsCloudDriveModuleText
        && containsRegex "macOS-only" windowsCloudDriveModuleText
      )
      "Only macOS may map iCloudReplica to native Mobile Documents; Windows must enforce managed directories";

  # Test 43: replica-sync runners enforce pull-only policy and avoid bisync execution paths
  test_replica_pull_only_policy = assert' (
    containsRegex "unsupported direction" replicaSyncShellText
    && containsRegex "pull-only by policy" replicaSyncShellText
    && containsRegex ''"direction":"pull"'' posixUsersText
    && containsRegex ''"direction":"pull"'' windowsUsersText
    && !containsRegex ''"direction":"bidirectional"'' posixUsersText
    && !containsRegex ''"direction":"bidirectional"'' windowsUsersText
    && !containsRegex ''"direction":"push"'' posixUsersText
    && !containsRegex ''"direction":"push"'' windowsUsersText
    && !(containsRegex "rclone bisync" replicaSyncShellText)
    && !(containsRegex "--resync" replicaSyncShellText)
    && !(containsRegex "--check-access" replicaSyncShellText)
    && containsRegex "unsupported direction" windowsReplicaModuleText
    && containsRegex "pull-only by policy" windowsReplicaModuleText
    && !(containsRegex " bisync " windowsReplicaModuleText)
    && !(containsRegex "--resync" windowsReplicaModuleText)
    && !(containsRegex "--check-access" windowsReplicaModuleText)
  ) "Replica sync runners must enforce pull-only policy and avoid bisync state machinery";

  # Test 44: replica-sync entrypoints resolve repository root via env var
  test_replica_entrypoints_resolve_repo_root = assert' (containsRegex "Resolve-NucleusRepoRoot" replicaSyncPwshText) "Replica entrypoint scripts must resolve repo root via env var";

  # Test 45: fallbackTimer settings are wired to intended scheduled-sync runners on all hosts
  test_replica_fallback_timer_wiring = assert' (
    containsRegex "scheduledSyncReplicas" moduleText
    && containsRegex "mkReplicaScheduledSyncScript" moduleText
    && containsRegex "cloud-replica-scheduled-sync" moduleText
    && containsRegex "cloud-replica-scheduled-sync-" moduleText
    && containsRegex "StartCalendarInterval" moduleText
    && containsRegex "systemd\.user\.timers" moduleText
    && containsRegex "OnCalendar" moduleText
    && containsRegex "Sync-ReplicaSyncScheduledTask" windowsApplyText
    && containsRegex "New-ScheduledTaskTrigger" windowsReplicaScheduleModuleText
    && containsRegex "-Daily" windowsReplicaScheduleModuleText
    && containsRegex "nucleus-replica-sync" windowsReplicaScheduleModuleText
  ) "Replica fallbackTimer must materialize as daily scheduled-sync wiring on macOS/NixOS/Windows";

  # Test 46: macOS launchd inventory declares every remote-backed mount/replica and uses per-entry enable flags
  test_macos_launchd_inventory_is_declared =
    assert'
      (
        containsRegex "declaredMountAgents" moduleText
        && containsRegex "declaredScheduledSyncReplicas" moduleText
        && containsRegex "enable = mount\.enable" moduleText
        && containsRegex "enable = replica\.enable" moduleText
      )
      "macOS launchd inventory must declare all remote-backed mounts and scheduled replicas while respecting per-entry enable flags";

  # Test 47: replica-reset command is exposed on POSIX and Windows with dedicated scripts/modules
  test_replica_reset_command_parity = assert' (
    containsRegex "mkReplicaResetApp" flakeText
    && containsRegex "nucleus-replica-reset" flakeText
    && containsRegex ''name = "replica-reset"'' flakeText
    && containsRegex "function nucleus-replica-reset" shellProfileText
    && containsRegex ''scripts\\replica-reset\.ps1'' shellProfileText
    && containsRegex "Resolve-NucleusRepoRoot" replicaResetPwshText
    && containsRegex "Invoke-ReplicaReset" replicaResetPwshText
    && containsRegex "derive_repo_root" replicaResetShellText
    && containsRegex "clearing local replica data" replicaResetShellText
    && containsRegex "expected iCloud drive symlink" replicaResetShellText
    && !containsRegex ''mkdir -p "\\$local_root"'' replicaResetShellText
    && containsRegex "clears local replica data" windowsReplicaResetModuleText
    && containsRegex "expected iCloud drive symlink" windowsReplicaResetModuleText
    && !containsRegex ''New-Item -ItemType Directory -Path \\$localRoot'' windowsReplicaResetModuleText
    && containsRegex "function Invoke-ReplicaReset" windowsReplicaResetModuleText
  ) "replica-reset command must exist with parity on POSIX and Windows";

  # Test 48: Shared cleanup config must drive replica metadata cleanup behavior
  test_replica_gc_config_centralized = assert' (
    containsRegex ''"GoogleDrive"'' replicaGcConfigText
    && containsRegex ''"iCloud"'' replicaGcConfigText
    && containsRegex ''"OneDrive"'' replicaGcConfigText
    && containsRegex ''"files"'' replicaGcConfigText
    && containsRegex ''"dirs"'' replicaGcConfigText
    && containsRegex ''"remoteExcludes"'' replicaGcConfigText
    && containsRegex ''"blockedRoots"'' replicaGcConfigText
    && !containsRegex ''"macOSMetadata"'' replicaGcConfigText
    && !containsRegex ''"oneDrive"'' replicaGcConfigText
    && containsRegex ''cloudDrives\.replicaGc'' replicaSyncShellText
    && containsRegex "load_provider_gc_entries" replicaSyncShellText
    && containsRegex "Get-ReplicaGcConfig" windowsReplicaModuleText
    && containsRegex "userRecord.*replicaGc" windowsReplicaModuleText
  ) "replica metadata exclusion and GC patterns must be centralized in one shared config";

  # Test 49: Replica runners lock local replica trees as read-only between sync runs
  test_replica_read_only_permissions = assert' (
    containsRegex "set_replica_tree_writable" replicaSyncShellText
    && containsRegex "set_replica_tree_read_only" replicaSyncShellText
    && containsRegex "chmod -R a-w" replicaSyncShellText
    && containsRegex "Invoke-ReplicaTreeWritable" windowsReplicaModuleText
    && containsRegex "Invoke-ReplicaTreeReadOnly" windowsReplicaModuleText
    && containsRegex "icacls" windowsReplicaModuleText
    && containsRegex "deny write/create/delete" windowsReplicaModuleText
  ) "Replica sync runners must enforce read-only local replica permissions on POSIX and Windows";

  # Test 50: shared user registries keep cloud mounts read-write (including iCloud)
  test_mounts_read_write_matrix =
    assert'
      (
        containsRegex ''"id":"GoogleDrive"'' posixUsersText
        && containsRegex ''"id":"iCloud"'' posixUsersText
        && containsRegex ''"id":"OneDrive"'' posixUsersText
        && containsRegex ''"readWrite":true'' posixUsersText
        && containsRegex ''"readWrite":true'' windowsUsersText
      )
      "Cloud mount matrix must keep GoogleDrive/iCloud/OneDrive readWrite=true across POSIX and Windows registries";

  # Test 51: MacBook host override disables only GoogleDrive replica via list transform
  test_macbook_google_drive_replica_exception = assert' (
    containsRegex ''nucleus\.cloudDrives\.replicas = map'' macbookCloudOverrideText
    && containsRegex ''replica\.id == "GoogleDrive"'' macbookCloudOverrideText
    && containsRegex "enable = false" macbookCloudOverrideText
  ) "MacBook cloud override must disable only GoogleDrive replica with a list-based transform";

  # Test 52: POSIX cloud-setup.sh passes acknowledge_abuse in create args and runs config update for existing remotes
  test_cloud_setup_acknowledge_abuse =
    assert'
      (
        containsRegex "drive.*acknowledge_abuse" shellScriptText
        && containsRegex "rclone config update GoogleDrive acknowledge_abuse true" shellScriptText
      )
      "cloud-setup.sh must configure acknowledge_abuse=true for GoogleDrive during creation and existing remote update";

  # Test 53: Windows cloud-setup.ps1 passes acknowledge_abuse in create args and runs config update for existing remotes
  test_cloud_setup_pwsh_acknowledge_abuse =
    assert'
      (
        containsRegex "drive.*return.*acknowledge_abuse.*true" pwshScriptText
        && containsRegex "rclone config update GoogleDrive acknowledge_abuse true" pwshScriptText
      )
      "cloud-setup.ps1 must configure acknowledge_abuse=true for GoogleDrive during creation and existing remote update";

  # Test 54: replica readWrite option exists with bool type and defaults to false
  test_replica_readWrite_option = assert' (
    containsRegex "readWrite = lib\\.mkOption" moduleText
    && containsRegex "type = lib\\.types\\.bool" moduleText
    && containsRegex "default = false" moduleText
  ) "replicaSubmodule must declare readWrite option of type bool defaulting to false";

  # Test 55: replica name option exists with nullOr str type and defaults to null
  test_replica_name_option = assert' (
    containsRegex "name = lib\\.mkOption" moduleText
    && containsRegex "type = lib\\.types\\.nullOr lib\\.types\\.str" moduleText
    && containsRegex "default = null" moduleText
  ) "replicaSubmodule must declare name option of type nullOr str defaulting to null";

  # Test 56: replica direction is restricted to pull-only
  test_replica_direction_restricted = assert' (
    containsRegex ''enum.*"pull"'' moduleText
    && !(containsRegex ''"bidirectional"'' moduleText)
    && !(containsRegex ''"push"'' moduleText)
  ) "replica direction must be restricted to enum [\"pull\"] with no bidirectional or push values";

  # Test 57: realtime option is removed from replica submodule
  test_replica_realtime_removed = assert' (
    !(containsRegex "replicaRealtimeSubmodule" moduleText) && !(containsRegex "realtime" moduleText)
  ) "replicaRealtimeSubmodule and realtime option must be removed from cloud-drives module";

  # Test 58: remoteName is removed from replica submodule (mounts still have it)
  test_replica_remoteName_removed = assert' (
    # mount submodule still declares remoteName as an option
    containsRegex "mountSubmodule" moduleText
    && containsRegex "remoteName = lib[.]mkOption" moduleText
    # replica submodule does NOT declare remoteName as an option
    && !(containsRegex ''replicaSubmodule = lib[.]types[.]submodule \{.*remoteName = lib[.]mkOption'' moduleText)
  ) "remoteName option must be removed from replicaSubmodule (mounts may still declare it)";

  # Test 59: GoogleDrive replica sets name in both registries
  test_replica_name_in_configs = assert' (
    containsRegex ''"id":"GoogleDrive"'' posixUsersText
    && containsRegex ''"name":"Google Drive"'' posixUsersText
    && containsRegex ''"name":"Google Drive"'' windowsUsersText
  ) "GoogleDrive replica must set name=\"Google Drive\" in both POSIX and Windows registries";

  # Test 60: POSIX iCloud replica sets readWrite=true (macOS symlink exception)
  test_icloud_replica_readwrite_posix =
    let
      icloudReplica = builtins.head (
        builtins.filter (replica: (replica.id or "") == "iCloud") polyipseityMacBook.cloudDrives.replicas
      );
    in
    assert' (
      icloudReplica.readWrite or false == true
    ) "POSIX iCloud replica must set readWrite=true for macOS symlink exception";

  # Test 61: Windows iCloud replica does NOT set readWrite (managed directories, not symlinks)
  test_icloud_replica_readwrite_windows =
    let
      icloudReplica = builtins.head (
        builtins.filter (replica: (replica.id or "") == "iCloud") polyipseityWindows.cloudDrives.replicas
      );
    in
    assert' (
      !(icloudReplica ? readWrite) || icloudReplica.readWrite == false
    ) "Windows iCloud replica must not enable readWrite (uses managed real directories, not symlinks)";

  # Test 62: replica runner scripts conditionally lock read-only based on readWrite flag
  test_replica_conditional_readonly_locking = assert' (
    containsRegex "read_write" replicaSyncShellText
    && containsRegex "set_replica_tree_read_only" replicaSyncShellText
    && containsRegex "readWrite" windowsReplicaModuleText
    && containsRegex "Invoke-ReplicaTreeReadOnly" windowsReplicaModuleText
  ) "replica sync runners must conditionally set read-only based on the readWrite config flag";

  allTests = [
    test_options_exist
    test_mounts_are_list
    test_replicas_are_list
    test_replica_enable_defaults_false
    test_mount_enable_defaults_true
    test_provider_enum_values
    test_reads_user_config
    test_icloud_not_brctl_only
    test_rclone_package_conditional
    test_setup_activation_exists
    test_no_icloud_refresh_activation
    test_macos_launchd_agents
    test_nixos_systemd_services
    test_list_schema_allows_multiple
    test_icloud_service_option_exists
    test_icloud_mounts_pass_service
    test_user_registries_define_icloud_service
    test_cloud_setup_runtime_has_jq
    test_cloud_setup_passes_icloud_service
    test_rclone_options_in_home_nix
    test_cloud_drives_password_command
    test_cloud_setup_exports_rclone_pass
    test_cloud_setup_uses_root_only_listing
    test_finder_sidebar_automatic_strategy
    test_cloud_mounts_prepare_volumes
    test_cloud_mounts_use_fskit_backend
    test_cloud_setup_recreates_stale_remotes
    test_macos_uses_fuse_t
    test_google_drive_name
    test_icloud_replica_disabled
    test_flake_has_replica_command
    test_flake_has_replica_app
    test_apply_runs_replica_sync
    test_finder_sidebar_paths_created
    test_macos_skips_icloud_replica
    test_windows_replica_sync_entrypoints
    test_windows_apply_replica_hook
    test_windows_shell_replica_command
    test_onedrive_personal_vault_excluded
    test_icloud_replica_platform_invariant
    test_replica_pull_only_policy
    test_replica_entrypoints_resolve_repo_root
    test_replica_fallback_timer_wiring
    test_macos_launchd_inventory_is_declared
    test_replica_reset_command_parity
    test_replica_gc_config_centralized
    test_replica_read_only_permissions
    test_mounts_read_write_matrix
    test_macbook_google_drive_replica_exception
    test_cloud_setup_acknowledge_abuse
    test_cloud_setup_pwsh_acknowledge_abuse
    test_replica_readWrite_option
    test_replica_name_option
    test_replica_direction_restricted
    test_replica_realtime_removed
    test_replica_remoteName_removed
    test_replica_name_in_configs
    test_icloud_replica_readwrite_posix
    test_icloud_replica_readwrite_windows
    test_replica_conditional_readonly_locking
  ];
in
let
  # Force all assertions — if any fails, builtins.all aborts with the thrown error.
  _allPassed = builtins.all (test: test == null) allTests;
in
{
  success = _allPassed;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud-drives schema tests passed";
}
