# macOS-only LaunchAgents (extracted from default.nix for focused maintainability).
#
# All agents here are user-scoped LaunchAgents (domain = "gui") so each user
# can configure them individually and launchd loads them without the
# root-domain mismatch warning that global launchd.agents trigger under
# nix-darwin.
#
# Each agent sets enable = true: HM's launchd module filters agents by that
# flag, so an agent without it generates no plist.
{
  config,
  lib,
  pkgs,
  username,
  nucleusApps,
  users ? null,
  hostName,
  ...
}:
let
  # Cached imports for all env-var-related callsites below.
  # managed-paths.nix for PATH components; env/env-secrets.json for catalog/resolution.
  managedPaths = import ../../../modules/lib/managed-paths.nix { inherit pkgs; };
  envVars = import ../../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };

  # Managed dirs (prepend and append) as a colon-joined lookup set for
  # stripping stale PATH entries. Membership only, so the order inside the
  # string is irrelevant. The prefix is an absolute home directory because
  # launchd does no shell expansion, so "$HOME" would stay literal.
  mkManagedDedupSet =
    prefix:
    builtins.concatStringsSep ":" (
      map (p: "${prefix}/${p}") (
        managedPaths.pathComponents.prepend ++ managedPaths.pathComponents.append
      )
    );

  # Restrict exclusions to ~/Library/Mobile Documents subpaths, so symlinks
  # like ~/Downloads/iCloud are never traversed.
  sanitizeICloudManagedRoots =
    roots:
    let
      normalizeRoot = root: lib.removeSuffix "/." root;
      normalizedRoots = map normalizeRoot roots;
      mobileDocumentsRoots = builtins.filter (
        root: root != "Library/Mobile Documents" && lib.hasPrefix "Library/Mobile Documents/" root
      ) normalizedRoots;
    in
    if mobileDocumentsRoots != [ ] then
      mobileDocumentsRoots
    else
      [ "Library/Mobile Documents/com~apple~CloudDocs" ];

  # Payloads evaluated at derivation time, so the store script needs no
  # runtime user context. Both mirror macos-configure-icloud-exclusions to keep
  # the activation hook and the daily agent in sync.
  icloudExcludedDirsJson = builtins.toJSON (
    let
      effectiveUsers = if users != null then users else { };
      currentUser = config.home.username;
    in
    if
      builtins.hasAttr currentUser effectiveUsers
      && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
      && builtins.hasAttr "excludedDirNames" effectiveUsers.${currentUser}.iCloudExclusions
    then
      effectiveUsers.${currentUser}.iCloudExclusions.excludedDirNames
    else
      [ ]
  );

  icloudManagedRootsJson = builtins.toJSON (
    let
      effectiveUsers = if users != null then users else { };
      currentUser = config.home.username;
    in
    if
      builtins.hasAttr currentUser effectiveUsers
      && builtins.hasAttr "iCloudExclusions" effectiveUsers.${currentUser}
      && builtins.hasAttr "managedRoots" effectiveUsers.${currentUser}.iCloudExclusions
    then
      sanitizeICloudManagedRoots effectiveUsers.${currentUser}.iCloudExclusions.managedRoots
    else
      sanitizeICloudManagedRoots [ ]
  );

  icloudExclusionsScript = pkgs.writeNucleusShellApplication {
    name = "icloud-exclusions";
    runtimeInputs = [ ]; # tools resolved by absolute paths passed as args
    scriptName = "src/scripts/services/icloud-exclusions";
  };

  betterdisplayHeartbeat = pkgs.writeNucleusShellApplication {
    name = "betterdisplay-heartbeat";
    scriptName = "src/platforms/macOS/scripts/macos-heartbeat-betterdisplay";
  };

  # In the Nix store so the ProgramArguments path is stable across
  # home-manager generations. The freshness check matters because the plist
  # embeds the derivation path, so every switch reloads the agent; skipping a
  # rebuild when the database is under 6 days old keeps apply fast.
  nixIndexUpdate = pkgs.writeNucleusShellApplication {
    name = "nix-index-update";
    runtimeInputs = [ pkgs.nix-index ];
    scriptName = "src/scripts/packages/update-nix-index";
  };

  # `.metadata_never_index` is a Finder/Spotlight convention, so this list is
  # macOS-only.
  devSpotlightExcludedDirectoryNames = [
    ".gradle"
    ".next"
    ".turbo"
    ".venv"
    "__pycache__"
    "bin"
    "build"
    "dist"
    "incremental"
    "node_modules"
    "obj"
    "target"
    "vendor"
    "venv"
  ];

  # Not an activation hook: a full scan of a large worktree would noticeably
  # delay `nix run .#apply`.
  spotlightExclusions = pkgs.writeNucleusShellApplication {
    name = "spotlight-exclusions";
    runtimeInputs = [ ];
    scriptName = "src/platforms/macOS/scripts/macos-configure-spotlight-exclusions";
  };

  # Not an activation hook, same reason as the Spotlight markers: deleting
  # stale .DS_Store files takes noticeable time on a large checkout.
  dsStoreGc = pkgs.writeNucleusShellApplication {
    name = "ds-store-gc";
    runtimeInputs = [ ];
    scriptName = "src/scripts/services/ds-store-gc";
  };

  sccacheGc = pkgs.writeNucleusShellApplication {
    name = "sccache-gc";
    runtimeInputs = [ pkgs.sccache ];
    scriptName = "src/scripts/services/sccache-gc";
  };

  # WHY: logGcUser is centralized in gc-activations.nix for cross-host reuse.
  gcApps = import ../../../modules/gc-activations.nix { inherit pkgs; };
  inherit (gcApps) logGcUser;

  # guiEnvAgent — launchd login agent that manages GUI-environment PATH and
  # env vars.  All Nix-computed values are passed as CLI args to the script.
  guiEnvAgent = pkgs.writeNucleusShellApplication {
    name = "gui-env";
    runtimeInputs = [ ];
    scriptName = "src/platforms/macOS/scripts/macos-set-gui-env";
  };
in
{
  # Daily sccache cache clearing at 12:00, between weekly GC runs, so the cache
  # cannot grow unbounded.
  launchd.agents."sccache-gc" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.sccache-gc";
      ProgramArguments = [ "${sccacheGc}/bin/nucleus-sccache-gc" ];
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  # Daily user log rotation at noon.
  launchd.agents."log-gc-user" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.log-gc-user";
      ProgramArguments = [ "${logGcUser}/bin/nucleus-log-gc-user" ];
      EnvironmentVariables = {
        NUCLEUS_LOG_EXPIRY = config.nucleus.logging.rotation.expiry;
      };
      RunAtLoad = false;
      # WHY: StartCalendarInterval is broken on this system — see posix/base.nix.
      StartInterval = 86400;
    };
  };

  # Polls the HeadlessDisplay virtual screen every 60 seconds and reconnects it.
  # A launchd agent rather than macos-headless-display alone: that runs only
  # during `home-manager switch`, and a clamshell Mac left closed can lose the
  # virtual screen connection without a new activation run. KeepAlive gives
  # crash recovery without a Pro subscription or kernel extension.
  launchd.agents."betterdisplay-heartbeat" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.betterdisplay-heartbeat";
      ProgramArguments = [ "${betterdisplayHeartbeat}/bin/nucleus-betterdisplay-heartbeat" ];
      # Start at login and stay alive; the internal loop handles the interval.
      RunAtLoad = true;
      KeepAlive = true;
      # WHY: the house default is the stdout.log/stderr.log pair for every service.
      # Rotation bounds the file, so the loop's no-op output stays diagnosable
      # without filling the log tree.
      StandardOutPath = "${config.nucleus.logging.logDir}/betterdisplay-heartbeat/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.logDir}/betterdisplay-heartbeat/stderr.log";
    };
  };

  # Dev-tree maintenance runs as background jobs so apply stays synchronous
  # only for work that has to happen immediately.
  launchd.agents."ds-store-gc" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.ds-store-gc";
      ProgramArguments = [ "${dsStoreGc}/bin/nucleus-ds-store-gc" ];
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  launchd.agents."spotlight-exclusions" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.spotlight-exclusions";
      ProgramArguments = [
        "${spotlightExclusions}/bin/nucleus-spotlight-exclusions"
        (builtins.concatStringsSep " " devSpotlightExcludedDirectoryNames)
      ];
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  # Keeps the nix-index database current so pay-respects can suggest
  # `nix profile install` commands. Not a synchronous activation step: a full
  # build takes minutes and would block the activation chain. A stale database
  # only means pay-respects stops suggesting packages, so failure is benign.
  launchd.agents."nix-index-update" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.nix-index-update";
      ProgramArguments = [
        "${nixIndexUpdate}/bin/nucleus-nix-index-update"
        "nix-index"
        "6"
      ];
      # A freshly provisioned machine gets a rebuild at load rather than
      # waiting for the next daily window.
      RunAtLoad = true;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
      # WHY: the house default is the stdout.log/stderr.log pair for every service.
      StandardOutPath = "${config.nucleus.logging.logDir}/nix-index-update/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.logDir}/nix-index-update/stderr.log";
    };
  };

  # Hourly drift correction for directories created between activations;
  # the activation hook already covers the immediate case.
  launchd.agents."icloud-exclusions" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.icloud-exclusions";
      ProgramArguments = [
        "${icloudExclusionsScript}/bin/nucleus-icloud-exclusions"
        "${pkgs.jq}/bin/jq"
        "${pkgs.findutils}/bin/find"
        icloudExcludedDirsJson
        icloudManagedRootsJson
      ];
      # The activation hook runs synchronously on every apply, so this agent
      # only corrects drift.
      RunAtLoad = false;
      StartInterval = 3600;
    };
  };

  # Checks user-scope nucleus services every 5 minutes as the logged-in user, so
  # it can reach ~/Library/LaunchAgents. In home-manager to keep root-launched
  # activation from managing user-scope agents.
  launchd.agents."service-watchdog-user" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.service-watchdog-user";
      ProgramArguments = [
        "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog"
        "--scope"
        "user"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.nucleus.logging.logDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.logDir}/service-watchdog/stderr.log";
      EnvironmentVariables = {
        NUCLEUS_SERVICES_JSON = import ../../../modules/lib/services-json-path.nix { };
      };
    };
  };

  # Shell sessionVariables never cross into the GUI launchd domain, so
  # launchctl setenv runs here at login for the GUI apps that need it. The var
  # list comes from macBookAllVars in src/modules/lib/env-secrets.nix; all
  # MacBook values are safe because the GUI domain is per-user.
  launchd.agents."gui-env" = {
    enable = true;
    domain = "gui";
    config = {
      Label = "local.gui-env";
      ProgramArguments = [
        "${guiEnvAgent}/bin/nucleus-gui-env"
        (managedPaths.toAbsolutePrependPath config.home.homeDirectory)
        (managedPaths.toAbsoluteAppendPath config.home.homeDirectory)
        (mkManagedDedupSet config.home.homeDirectory)
        envVars.macBookAllVars
      ];
      # One-shot at login; gui-env-path re-applies on every apply.
      RunAtLoad = true;
    };
  };
}
