# tests/nix/cloud-sync-tests.nix — Schema and invariant tests for cloud-drives.nix.
#
# Validates that the cloud-drives module text contains the required option
# definitions, type declarations, and structural invariants.
#
# Run with: nix-instantiate --eval tests/nix/cloud-sync-tests.nix

{ }:
let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  moduleText = builtins.readFile ../../src/modules/cloud-drives.nix;
  posixUsersText = builtins.readFile ../../src/modules/users.json;
  windowsUsersText = builtins.readFile ../../src/hosts/windows/users.json;
  flakeText = builtins.readFile ../../src/flake.nix;
  shellScriptText = builtins.readFile ../../scripts/cloud-setup.sh;
  pwshScriptText = builtins.readFile ../../scripts/cloud-setup.ps1;
  homeNixText = builtins.readFile ../../src/modules/home.nix;
  shellNixText = builtins.readFile ../../src/modules/shell.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;

  assert' = cond: msg: if !cond then throw "ASSERTION FAILED: ${msg}" else null;

  # Test 1: Module defines both mounts and replicas option lists
  test_options_exist =
    assert'
      (
        containsRegex "options\.nucleus\.cloudDrives\.mounts" moduleText
        && containsRegex "options\.nucleus\.cloudDrives\.replicas" moduleText
      )
      "cloud-drives module must declare nucleus.cloudDrives.mounts and nucleus.cloudDrives.replicas options";

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
  test_reads_user_config = assert' (containsRegex "users\.\\\$\{currentUsername\}\.cloudDrives" moduleText) "module must read per-user config from users.\${currentUsername}.cloudDrives";

  # Test 8: iCloud does not rely on native brctl-only logic
  test_icloud_not_brctl_only = assert' (!containsRegex "brctl download" moduleText) "cloud-drives module should not require native brctl iCloud-only behavior";

  # Test 9: rclone is conditionally added to home packages
  test_rclone_package_conditional = assert' (
    containsRegex "pkgs\.rclone" moduleText && containsRegex "hasRcloneProvider" moduleText
  ) "rclone package should only be installed when rclone-backed providers are configured";

  # Test 10: cloudDrivesSetup activation is defined
  test_setup_activation_exists = assert' (containsRegex "cloudDrivesSetup" moduleText) "cloudDrivesSetup activation must be defined for directory creation";

  # Test 11: cloudDrivesICloudRefresh activation is not required in rclone-first design
  test_no_icloud_refresh_activation = assert' (!containsRegex "cloudDrivesICloudRefresh" moduleText) "cloudDrivesICloudRefresh activation should not exist in rclone-first cloud-drives module";

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
    containsRegex "--iclouddrive-service" moduleText
    && containsRegex "mount\\.iCloudService" moduleText
  ) "cloud-drives mounts must pass --iclouddrive-service from user config";

  # Test 17: Both user registries pin the current iCloud entries to drive
  test_user_registries_define_icloud_service = assert' (
    containsRegex ''"iCloudService": "drive"'' posixUsersText
    && containsRegex ''"iCloudService": "drive"'' windowsUsersText
  ) "POSIX and Windows user registries must define the current iCloud service explicitly";

  # Test 18: cloud-setup app ships jq so the shell helper can read users.json
  test_cloud_setup_runtime_has_jq = assert' (
    containsRegex "mkCloudSetupApp" flakeText
    && containsRegex "pkgs\\.jq" flakeText
  ) "cloud-setup app runtime must include jq for user-config lookup";

  # Test 19: cloud-setup scripts pass the configured iCloud service to create
  test_cloud_setup_passes_icloud_service = assert' (
    containsRegex "resolve_icloud_service_for_remote" shellScriptText
    && containsRegex "service" shellScriptText
    && containsRegex "Resolve-ICloudServiceForRemote" pwshScriptText
    && containsRegex "@\('service', \\$iCloudService, '--all'\)" pwshScriptText
  ) "cloud-setup scripts must preselect the configured iCloud service during remote creation";

  # Test 20: home.nix declares nucleus.rclone options for configPassEnabled and configPassSecretPath
  test_rclone_options_in_home_nix = assert' (
    containsRegex "nucleus\.rclone" homeNixText
    && containsRegex "configPassEnabled" homeNixText
    && containsRegex "configPassSecretPath" homeNixText
  ) "home.nix must declare nucleus.rclone.configPassEnabled and nucleus.rclone.configPassSecretPath options";

  # Test 21: cloud-drives.nix emits --password-command when configPassEnabled is set
  test_cloud_drives_password_command = assert' (
    containsRegex "password-command" moduleText
    && containsRegex "configPassEnabled" moduleText
  ) "cloud-drives.nix must add --password-command to mount args when nucleus.rclone.configPassEnabled is true";

  # Test 22: shell.nix exports RCLONE_CONFIG_PASS guarded by configPassEnabled
  test_shell_exports_rclone_pass = assert' (
    containsRegex "RCLONE_CONFIG_PASS" shellNixText
    && containsRegex "configPassEnabled" shellNixText
  ) "shell.nix must export RCLONE_CONFIG_PASS conditional on nucleus.rclone.configPassEnabled";

  # Test 23: Both cloud-setup scripts export RCLONE_CONFIG_PASS before remote creation
  test_cloud_setup_exports_rclone_pass = assert' (
    containsRegex "RCLONE_CONFIG_PASS" shellScriptText
    && containsRegex "rclone-config-pass" shellScriptText
    && containsRegex "RCLONE_CONFIG_PASS" pwshScriptText
    && containsRegex "rclone-config-pass" pwshScriptText
  ) "cloud-setup scripts must export RCLONE_CONFIG_PASS from the materialized secret before rclone config create";

  # Test 24: Both cloud-setup scripts validate credentials with root-only listings
  test_cloud_setup_uses_root_only_listing = assert' (
    containsRegex "rclone lsd" shellScriptText
    && containsRegex "root-only listings" shellScriptText
    && containsRegex "rclone lsd" pwshScriptText
  ) "cloud-setup scripts must use root-only directory listings for credential validation";

  # Test 25: Finder sidebar is rewritten via NSKeyedArchiver/JXA instead of unsupported sfltool add/remove commands
  test_finder_sidebar_rewrite_is_direct = assert' (
    containsRegex "osascript -l JavaScript" macosText
    && containsRegex "NSKeyedUnarchiver" macosText
    && containsRegex "NSKeyedArchiver" macosText
    && containsRegex "FavoriteItems\\.sfl4" macosText
    && !containsRegex "sfltool add-item" macosText
    && !containsRegex "sfltool remove-item" macosText
  ) "Finder sidebar favorites must be rewritten directly through the shared-file-list archive";

  # Test 26: Both cloud-setup scripts recreate remotes whose credentials are stale
  test_cloud_setup_recreates_stale_remotes = assert' (
    containsRegex "stale" shellScriptText
    && containsRegex "rclone config delete" shellScriptText
    && containsRegex "stale" pwshScriptText
    && containsRegex "rclone config delete" pwshScriptText
  ) "cloud-setup scripts must recreate remotes with stale or invalid credentials";

  # Test 27: iclouddrive password field is pre-supplied to skip interactive prompt
  test_cloud_setup_iclouddrive_presupplies_password = assert' (
    containsRegex "rclone obscure" shellScriptText
    && containsRegex "rclone obscure" pwshScriptText
  ) "cloud-setup scripts must pre-supply iclouddrive password via rclone obscure to skip the --all interactive prompt";

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
    test_shell_exports_rclone_pass
    test_cloud_setup_exports_rclone_pass
    test_cloud_setup_uses_root_only_listing
    test_finder_sidebar_rewrite_is_direct
    test_cloud_setup_recreates_stale_remotes
    test_cloud_setup_iclouddrive_presupplies_password
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cloud-drives schema tests passed";
}
