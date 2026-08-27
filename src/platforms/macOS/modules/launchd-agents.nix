# macOS-only LaunchAgents (extracted from default.nix for focused maintainability).
#
# All agents here are user-domain LaunchAgents (domain = "user") so each user
# can configure them individually and launchd loads them without the
# root-domain mismatch warning that global launchd.agents trigger under
# nix-darwin.
{
  config,
  lib,
  pkgs,
  repoRoot,
  username,
  nucleusApps,
  users ? null,
  hostName,
  ...
}:
let
  # Cached imports for all env-var-related callsites below.
  # managed-paths.nix for PATH components; env-catalog.nix for catalog/resolution.
  managedPaths = import ../../../modules/lib/managed-paths.nix { inherit pkgs; };
  envVars = import ../../../modules/lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };

  # ── Managed dirs dedup SET helper ──────────────────────────────────
  # Returns a colon-joined string of ALL managed dirs (both prepend and
  # append) for use as a case-pattern LOOKUP SET when stripping stale
  # entries from the current PATH before re-adding them.
  # This joins prepend+append as a SET for dedup — NOT as a PATH ordering.
  # The order within the returned string is irrelevant; only membership
  # matters.  The prefix argument is an absolute home directory resolved
  # at build time ("${config.home.homeDirectory}") for BOTH the activation
  # script and the launchd agent — launchd performs no shell expansion,
  # so "$HOME" would stay literal and never match real PATH entries.
  # Used by guiEnvAgent and gui-env-path activation step;
  # also informs launchctl config user path composition via pathComponents.
  mkManagedDedupSet =
    prefix:
    builtins.concatStringsSep ":" (
      map (p: "${prefix}/${p}") (
        managedPaths.pathComponents.prepend ++ managedPaths.pathComponents.append
      )
    );

  # Restrict iCloud exclusion to ~/Library/Mobile Documents subpaths.
  # Never traverse symlinks like ~/Downloads/iCloud or ~/clouds/iCloud.
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

  # Pre-computed JSON payloads for the iCloud exclusions launchd script.
  # Evaluated at derivation time so the standalone script can be placed in the
  # Nix store without needing runtime user-context access.  Both values mirror
  # the inline computation in macos-configure-icloud-exclusions to keep the activation
  # hook and the daily launchd agent in sync.
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

  # Daily launchd agent script for iCloud exclusion convergence.
  # Uses scriptName mode with runtime SCRIPT_DIR sourcing of the shared lib.
  # All values passed as positional args via ProgramArguments so the script
  # has no hardcoded paths or env-var dependencies.
  icloudExclusionsScript = pkgs.writeNucleusShellApplication {
    name = "icloud-exclusions";
    runtimeInputs = [ ]; # tools resolved by absolute paths passed as args
    scriptName = "src/scripts/services/icloud-exclusions";
  };

  betterdisplayHeartbeat = pkgs.writeNucleusShellApplication {
    name = "betterdisplay-heartbeat";
    runtimeInputs = [ ];
    scriptName = "src/platforms/macOS/scripts/macos-heartbeat-betterdisplay";
  };

  # Wrapper script for the nix-index daily database rebuild LaunchAgent.
  # Lives in the Nix store so the ProgramArguments path is stable across
  # home-manager generations without a home.file symlink.
  #
  # A freshness check prevents a full rebuild on every home-manager switch:
  # the LaunchAgent is reloaded on each switch because its plist embeds the
  # Nix store derivation path (which changes per generation).  Skipping the
  # rebuild when the DB was updated within the past 6 days keeps normal
  # apply runs fast.
  nixIndexUpdate = pkgs.writeNucleusShellApplication {
    name = "nix-index-update";
    runtimeInputs = [ pkgs.nix-index ];
    scriptName = "src/scripts/packages/update-nix-index";
  };

  # Directory names inside ~/dev whose contents should stay out of Spotlight.
  # This is intentionally macOS-only because `.metadata_never_index` is a
  # Finder/Spotlight convention, not a cross-host filesystem primitive.
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

  # Daily Spotlight exclusion refresh for the mutable ~/dev tree.
  # Kept out of Home Manager activation because large worktrees can make a full
  # scan slow enough to noticeably delay `nix run .#apply` and bootstrap apply.
  devSpotlightExclusions = pkgs.writeNucleusShellApplication {
    name = "spotlight-exclusions";
    runtimeInputs = [ ];
    scriptName = "src/platforms/macOS/scripts/macos-configure-spotlight-exclusions";
  };

  # Daily .DS_Store cleanup for ~/dev.
  # Kept out of Home Manager activation for the same reason as Spotlight marker
  # maintenance: deleting stale .DS_Store files can take noticeable time on a
  # large checkout and should not slow synchronous apply/bootstrap flows.
  devDsStoreGc = pkgs.writeNucleusShellApplication {
    name = "ds-store-gc";
    runtimeInputs = [ ];
    scriptName = "src/scripts/services/ds-store-gc";
  };

  sccacheGc = pkgs.writeNucleusShellApplication {
    name = "sccache-gc";
    runtimeInputs = [ pkgs.sccache ];
    scriptName = "src/scripts/services/sccache-gc";
  };

  logGcUser = pkgs.writeNucleusShellApplication {
    name = "log-gc-user";
    runtimeInputs = [ pkgs.jq ];
    scriptName = "src/scripts/services/log-gc-user";
  };

  # guiEnvAgent — launchd login agent that manages GUI-environment PATH and
  # env vars.  All Nix-computed values are passed as CLI args to the script.
  guiEnvAgent = pkgs.writeNucleusShellApplication {
    name = "gui-env";
    runtimeInputs = [ ];
    scriptName = "src/platforms/macOS/scripts/macos-set-gui-env";
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # --------------------------------------------------------------------------
  # Daily sccache cache clearing LaunchAgent
  # Clears the sccache compilation cache every day at 12:00 to prevent
  # unbounded cache growth between weekly GC runs. Cross-host parity with
  # NixOS systemd timer and Windows scheduled task.
  #
  # domain = "user" installs to ~/Library/LaunchAgents (the user's GUI/login
  # session) instead of /Library/LaunchAgents, so each user can configure it
  # individually and launchd loads it without the root-domain mismatch warning
  # that global launchd.agents trigger under nix-darwin.
  launchd.agents."sccache-gc" = {
    domain = "user";
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

  # --------------------------------------------------------------------------
  # Daily user log rotation LaunchAgent
  # Rotates user-scope nucleus logs daily at noon. Cross-host parity with
  # NixOS systemd user timer and Windows scheduled task.
  launchd.agents."log-gc-user" = {
    domain = "user";
    config = {
      Label = "local.log-gc-user";
      ProgramArguments = [ "${logGcUser}/bin/nucleus-log-gc-user" ];
      EnvironmentVariables = {
        NUCLEUS_GC_EXPIRY = config.modules.gc.expiry;
        NUCLEUS_REPO_ROOT = toString repoRoot;
      };
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  # --------------------------------------------------------------------------
  # BetterDisplay heartbeat LaunchAgent (macOS-only)
  # Persistent daemon that polls the HeadlessDisplay virtual screen every
  # 30 seconds and reconnects it if BetterDisplay marks it as disconnected.
  # Uses internal sleep loop (while true; do ...; sleep 30; done) so launchd
  # KeepAlive provides crash recovery.
  #
  # Why a LaunchAgent rather than relying on macos-headless-display alone:
  #   macos-headless-display runs only during `home-manager switch`.  On a
  #   clamshell Mac that is left closed for hours, BetterDisplay can drop the
  #   virtual screen connection without a new activation run.  A launchd
  #   persistent agent with KeepAlive is the lightest-weight fix without
  #   requiring a Pro subscription or kernel extension.
  #
  # Output is silenced to prevent log spam from 30-second no-op loop iterations.
  # --------------------------------------------------------------------------
  launchd.agents."betterdisplay-heartbeat" = {
    domain = "user";
    config = {
      Label = "local.betterdisplay-heartbeat";
      ProgramArguments = [ "${betterdisplayHeartbeat}/bin/nucleus-betterdisplay-heartbeat" ];
      # Start at login and stay alive; internal loop handles the 30 s interval.
      RunAtLoad = true;
      KeepAlive = true;
      # Suppress per-iteration output to avoid filling system logs.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };

  # --------------------------------------------------------------------------
  # Daily dev-tree maintenance LaunchAgents (macOS-only)
  # .DS_Store cleanup removes stale Finder metadata files from ~/dev.
  # Spotlight exclusion markers prevent Spotlight from indexing dev trees.
  # Keep them as background launchd jobs instead of activation hooks so
  # `nix run .#apply` and bootstrap apply stay synchronous only for
  # configuration work that must happen immediately.
  # --------------------------------------------------------------------------
  launchd.agents."ds-store-gc" = {
    domain = "user";
    config = {
      Label = "local.ds-store-gc";
      ProgramArguments = [ "${devDsStoreGc}/bin/nucleus-ds-store-gc" ];
      # Do not run on every agent reload during apply/bootstrap apply; daily
      # noon maintenance is sufficient for repository hygiene.
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
    domain = "user";
    config = {
      Label = "local.spotlight-exclusions";
      ProgramArguments = [
        "${devSpotlightExclusions}/bin/nucleus-spotlight-exclusions"
        (builtins.concatStringsSep " " devSpotlightExcludedDirectoryNames)
      ];
      # Do not run on every agent reload during apply/bootstrap apply; daily
      # noon maintenance is sufficient for dev-tree indexing hygiene.
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
    };
  };

  # --------------------------------------------------------------------------
  # nix-index rebuild LaunchAgent
  # Keeps the nix-index file database current so pay-respects can suggest
  # `nix profile install` commands when an unknown command is typed.
  #
  # Why a LaunchAgent rather than a synchronous activation step:
  #   A full nix-index build takes several minutes.  Running it inline during
  #   `home-manager switch` would block the activation chain on every apply.
  #   A launchd agent runs the build asynchronously after login, with a
  #   freshness guard that makes agent reloads during apply a fast no-op.
  #
  # Output is suppressed because nix-index emits verbose per-channel progress
  # on stdout even for successful builds, which would fill the system log.
  # This suppression is intentional: failure is benign (stale DB means
  # pay-respects falls back to not suggesting packages), and the agent retries
  # on the next daily run or load.  Check exit status with:
  #   launchctl list | grep nix-index-update
  # --------------------------------------------------------------------------
  launchd.agents."nix-index-update" = {
    domain = "user";
    config = {
      Label = "local.nix-index-update";
      ProgramArguments = [
        "${nixIndexUpdate}/bin/nucleus-nix-index-update"
        "nix-index"
        "6"
      ];
      # Run once at load so a freshly provisioned machine or a machine whose
      # DB is absent or stale gets an immediate rebuild rather than waiting
      # for the next daily calendar window.
      RunAtLoad = true;
      # Daily 12:00 rebuild keeps the index fresh without waiting a full week
      # after package additions or nixpkgs updates.
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
        }
      ];
      # Suppress per-build output to avoid filling system logs.  See above.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };

  # --------------------------------------------------------------------------
  # iCloud exclusion LaunchAgent (macOS-only)
  # Runs the iCloud directory exclusion logic hourly so that newly created
  # build/cache directories inside iCloud-managed trees are marked with
  # com.apple.fileprovider.ignore#P without waiting for the next home-manager
  # switch.  macos-configure-icloud-exclusions handles the immediate first-run case;
  # this agent provides drift correction between activations.
  # RunAtLoad = false because the activation hook already runs on every apply.
  # --------------------------------------------------------------------------
  launchd.agents."icloud-exclusions" = {
    domain = "user";
    config = {
      Label = "local.icloud-exclusions";
      ProgramArguments = [
        "${icloudExclusionsScript}/bin/nucleus-icloud-exclusions"
        "${pkgs.jq}/bin/jq"
        "${pkgs.findutils}/bin/find"
        icloudExcludedDirsJson
        icloudManagedRootsJson
      ];
      # Do not run on every agent reload during apply/bootstrap apply; the
      # activation hook (macos-configure-icloud-exclusions) runs synchronously during
      # apply and covers the immediate case.  The hourly timer handles drift
      # correction for directories created between activations.
      RunAtLoad = false;
      StartInterval = 3600;
    };
  };

  # --------------------------------------------------------------------------
  # User-level service watchdog LaunchAgent (macOS-only)
  # Persistent daemon that checks user-scope nucleus services every 5 minutes
  # with an internal 300s sleep loop.  Runs as the logged-in user so it can
  # reach ~/Library/LaunchAgents/ to check nucleus-managed user-scope launchd
  # services.  Kept in home-manager so root-launched activation does not trigger
  # macOS warnings about root managing user-scope agents.
  # --------------------------------------------------------------------------
  launchd.agents."service-watchdog-user" = {
    domain = "user";
    config = {
      Label = "local.service-watchdog-user";
      ProgramArguments = [
        "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog"
        "--domain"
        "user"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.nucleus.logging.logDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.logDir}/service-watchdog/stderr.log";
      EnvironmentVariables = {
        NUCLEUS_SERVICES_JSON = import ../../../modules/lib/services-json-path.nix { };
        NUCLEUS_REPO_ROOT = toString repoRoot;
      };
    };
  };

  # --------------------------------------------------------------------------
  # GUI environment variable propagation LaunchAgent (macOS-only)
  # macOS maintains separate shell (user/<uid>/) and GUI (gui/<uid>/) launchd
  # domains.  Shell sessionVariables set via home.sessionVariables never cross
  # into the GUI domain.  This agent calls launchctl setenv for every variable
  # that GUI applications (Obsidian, VS Code, oterm, etc.) need, providing
  # login-time coverage before the first activation.
  #
  # The var list for non-PATH vars is generated from the centralized catalog
  # — see src/modules/lib/env-catalog.nix (macBookAllVars).  All vars with a MacBook
  # value (both user and non-user) are included — safe because macOS launchd
  # GUI domains are per-user.
  #
  # This is a one-shot script (no loop) — launchctl setenv values persist in
  # the GUI domain until explicitly changed or reboot.  The gui-env-path
  # activation step re-applies all vars on every nucleus-apply.
  # --------------------------------------------------------------------------
  launchd.agents."gui-env" = {
    domain = "user";
    config = {
      Label = "local.gui-env";
      ProgramArguments = [
        "${guiEnvAgent}/bin/nucleus-gui-env"
        (managedPaths.toAbsolutePrependPath config.home.homeDirectory)
        (managedPaths.toAbsoluteAppendPath config.home.homeDirectory)
        (mkManagedDedupSet config.home.homeDirectory)
        envVars.macBookAllVars
      ];
      # One-shot at login; gui-env-path activation step covers subsequent applies.
      RunAtLoad = true;
    };
  };
}
