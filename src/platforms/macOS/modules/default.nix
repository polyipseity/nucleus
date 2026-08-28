# macOS-only activation hooks and LaunchAgents.
{
  config,
  lib,
  pkgs,
  repoRoot,
  username,
  users ? null,
  hostName,
  nucleusApps,
  ...
}:
let
  overlay = (import ../../../modules/lib/users-overlay.nix).mkUserOverlay {
    effectiveUsername = config.home.username;
    inherit repoRoot;
  };

  linearmouseConfigFile = overlay.selectFile "linearmouse" "linearmouse.json";

  liveICloudDownloads = "${config.home.homeDirectory}/Library/Mobile Documents/com~apple~CloudDocs/Downloads";

  # Sub-module imports extracted from this file for focused maintainability.
  finderSidebar = import ./finder-sidebar.nix { inherit config lib pkgs; };

  # macOS LaunchAgents (sccache-gc, log-gc-user, betterdisplay-heartbeat,
  # ds-store-gc, spotlight-exclusions, nix-index-update, icloud-exclusions,
  # service-watchdog-user, gui-env).  Imported as a fragment and merged into
  # the isDarwin-guarded config below; only ever loaded on macOS.
  launchdAgents = import ./launchd-agents.nix {
    inherit
      config
      lib
      pkgs
      repoRoot
      username
      nucleusApps
      users
      hostName
      ;
  };

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

  # UTI list for Chrome: set as the default handler for HTML and XHTML documents.: set as the default handler for HTML and XHTML documents.
  # Source: Apple Uniform Type Identifiers.
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  chromeUTIs = [
    "public.html"
    "public.xhtml"
  ];

  # UTI list for Keka: covers 7z, RAR, and ZIP archive formats so that opening
  # any archive file launches Keka for graphical extraction/creation.
  # Sources:
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  # https://github.com/moretension/duti
  kekaUTIs = [
    "public.zip-archive"
    "com.rarlab.rar-archive"
  ];

  # UTI list for VLC: covers the full range of video, audio, and playlist
  # formats that VLC supports so that double-clicking any media file opens VLC.
  # Sources:
  # https://developer.apple.com/documentation/uniformtypeidentifiers
  # https://github.com/moretension/duti
  vlcUTIs = [
    "public.movie"
    "public.video"
    "public.audio"
    "public.audiovisual-content"
    "public.mp3"
    "public.mpeg"
    "public.mpeg-4"
    "public.mpeg-2-video"
    "public.mpeg-2-transport-stream"
    "com.apple.quicktime-movie"
    "com.apple.m4a-audio"
    "com.apple.m4v-video"
    "public.avi"
    "public.3gpp"
    "public.3gpp2"
    "org.xiph.flac"
    "org.matroska.mka"
    "org.matroska.mkv"
    "org.videolan.webm"
    "org.xiph.ogg-audio"
    "org.xiph.ogg-video"
    "org.xiph.opus"
    "com.microsoft.advanced-systems-format"
    "com.real.realaudio"
    "com.real.realmedia"
    "public.dv-movie"
    "org.smpte.mxf"
    "public.flc-animation"
    "public.aiff-audio"
    "com.microsoft.waveform-audio"
    "public.aifc-audio"
    "com.apple.coreaudio-format"
    "public.m3u-playlist"
    "public.pls-playlist"
  ];

  # Absolute path to the duti binary supplied by nixpkgs.
  dutiBin = "${pkgs.duti}/bin/duti";

  # Periodic heartbeat script for the BetterDisplay virtual screen.
  # Lives in the Nix store so the LaunchAgent ProgramArguments path is stable
  # across home-manager generations without a home.file symlink.
  # set +e at the top makes all operations fully soft-fail so launchd never
  # marks the agent as failed and throttles future invocations.
  #
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

  # fdaWarningFunction extracted to src/scripts/lib/macos-fda-warning.sh

  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home.packages = [
    pkgs.mysides
  ];

  # Merge the macOS LaunchAgents defined in ./launchd-agents.nix.
  launchd.agents = launchdAgents.launchd.agents;

  home.file = {
    # Keep iCloud Downloads reachable from a short stable path without
    # replacing ~/Downloads itself.
    "Downloads/iCloud".source = config.lib.file.mkOutOfStoreSymlink liveICloudDownloads;
  };

  home.activation.macos-unprotect-icloud-downloads-symlink =
    lib.hm.dag.entryBefore [ "linkGeneration" ]
      ''
        "${activationBundle}/src/scripts/configs/managed-symlink.sh" "unprotect" "macos.nix" "$HOME/Downloads/iCloud"
      '';

  home.activation.macos-protect-icloud-downloads-symlink =
    lib.hm.dag.entryAfter [ "linkGeneration" ]
      ''
        "${activationBundle}/src/scripts/configs/managed-symlink.sh" "protect" "macos.nix" "$HOME/Downloads/iCloud"
      '';

  home.activation = {
    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    # macos-configure-display-resolutions
    # Uses displayplacer to match all external monitors to the MacBook's built-in
    # display mode so that remote-desktop clients see a consistent resolution.
    #
    # Algorithm:
    #   1. Identify the built-in screen's persistent ID and its current mode.
    #   2. If the built-in is on mode 4 (high-DPI Retina mode), apply it first
    #      to ensure the reference resolution is set correctly.
    #   3. Re-read the current mode string to obtain target width/height and
    #      the scaling flag.
    #   4. For each external display, find the mode whose width ≥ target width
    #      and height ≤ target height (so it fits within the same logical area)
    #      with the smallest height (closest match without overshooting).
    #
    # No-op if displayplacer is not installed.
    # -------------------------------------------------------------------------
    macos-configure-display-resolutions =
      lib.hm.dag.entryAfter [ "macos-configure-headless-display" ]
        ''
          "${activationBundle}/src/platforms/macOS/scripts/macos-display-resolutions.sh"
        '';

    # -------------------------------------------------------------------------
    # input-config
    # Writes input-method defaults that cannot be expressed in the nix-darwin
    # system.defaults tree because they require a running input method daemon
    # reload to take effect at session time.
    #
    #   hotkey 176 disabled  — disable the built-in "Move focus to next window"
    #                          shortcut that conflicts with custom window managers.
    #                          Uses -dict-add (merge), which cannot be expressed
    #                          as a plain defaults write in CustomUserPreferences.
    #   activateSettings -u  — flush keyboard/input settings into the running session
    #   killall TISwitcher   — restart the input-source switcher daemon so changes
    #                          to TISCapslockLanguageSwitch / FnKeyUsage take effect
    #
    # TISCapslockLanguageSwitch, AppleDictationAutoEnable, and FnKeyUsage are
    # now handled declaratively in defaults.nix via CustomUserPreferences.
    # -------------------------------------------------------------------------
    macos-configure-input-config = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-input-config.sh"
    '';

    # -------------------------------------------------------------------------
    # reloadUserPreferenceState
    # Forces macOS to flush/reload user defaults after all managed defaults
    # writes and domain-specific hooks.  This minimizes "ghost" values staying
    # in memory until logout/login after a rebuild.
    # -------------------------------------------------------------------------
    macos-reload-user-preference-state = lib.hm.dag.entryAfter [ "macos-configure-input-config" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-reload-user-preference-state.sh"
    '';

    # -------------------------------------------------------------------------
    # linearmouse-config
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    # Creates out-of-store symlinks for LinearMouse's runtime config files
    # pointing into the repository tree. Resolves the repo root at activation
    # time so the link survives repo relocations and rebuilds without stale
    # store paths.
    # check-suppress:config-method: method 1 (writable symlink) -- linearmouse/linearmouse.json deployed via linearmouse-config.sh
    # -------------------------------------------------------------------------
    macos-configure-linearmouse = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-linearmouse.sh" ${lib.escapeShellArg linearmouseConfigFile}
    '';

    # -------------------------------------------------------------------------
    # macos-launch-services
    # Registers default application handlers for file types using duti.
    # Running this in a Home Manager activation keeps the associations in sync
    # every time `home-manager switch` is run, which is necessary because
    # application (re)installs can reset handler registrations.
    #
    #   Chrome — handles all HTML/XHTML documents
    #   Keka   — handles .7z, .rar, and .zip archives
    #   VLC    — handles the complete set of audio/video UTIs defined above
    # -------------------------------------------------------------------------
    macos-configure-launch-services = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-launch-services.sh" "${dutiBin}" '${
        builtins.toJSON [
          {
            bundle_id = "com.google.chrome";
            utis = chromeUTIs;
          }
          {
            bundle_id = "com.aone.keka";
            utis = kekaUTIs;
          }
          {
            bundle_id = "org.videolan.vlc";
            utis = vlcUTIs;
          }
        ]
      }'
    '';

    # -------------------------------------------------------------------------
    # raycast-aliases
    # Raycast currently does not expose a dedicated language toggle for app-name
    # matching. On non-English macOS installations, localized display names can
    # therefore make English queries miss built-in apps.
    #
    # Mitigation: publish a managed set of English-named .app symlink aliases
    # under ~/Applications/Nucleus App Aliases so Spotlight/Raycast can index
    # additional English tokens without changing the system UI language.
    # -------------------------------------------------------------------------
    macos-install-raycast-aliases = lib.hm.dag.entryAfter [ "macos-configure-launch-services" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-install-raycast-aliases.sh"
    '';

    # -------------------------------------------------------------------------
    # nightlight
    # Enables the macOS Night Shift schedule via the nightlight CLI tool and
    # applies a colour temperature of 50 % (roughly 4000 K).  Immediately
    # activates or deactivates the filter based on the current hour so the
    # display is always in the correct state right after an activation.
    #
    # Schedule: 18:00 → 06:00 (nightlight schedule start uses default times).
    # No-op if nightlight is not installed.
    # Source: https://github.com/smudge/nightlight
    # -------------------------------------------------------------------------
    macos-install-nightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-install-nightlight.sh"
    '';

    # -------------------------------------------------------------------------
    # macos-configure-icloud-exclusions
    # Marks directories matching configured names with the com.apple.fileprovider
    # .ignore#P xattr to exclude them from iCloud sync. This prevents large
    # directories (e.g., node_modules, .venv) from syncing across devices.
    #
    # Scope guard:
    #   1. Managed roots come from the centralized src/users/ registry.
    #   2. At evaluation time we discard any root outside Library/Mobile Documents.
    #   3. At runtime we recurse only inside those native iCloud directories.
    #   4. find -prune stops descent into excluded directories, keeping scans fast.
    #
    # Configuration: excludedDirNames from src/users/ (e.g., ["node_modules"])
    # Source: https://developer.apple.com/documentation/fileprovider
    # -------------------------------------------------------------------------
    macos-configure-icloud-exclusions = lib.hm.dag.entryAfter [ "cloud-drives-setup" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-icloud-exclusions.sh" "${pkgs.jq}/bin/jq" "${pkgs.findutils}/bin/find" ${lib.escapeShellArg icloudExcludedDirsJson} ${lib.escapeShellArg icloudManagedRootsJson}
    '';

    # -------------------------------------------------------------------------
    # macos-check-privacy-permissions
    # Detects privacy-gated preference access problems early and emits an
    # explicit Full Disk Access remediation block so activation logs explain why
    # subsequent defaults writes may fail.
    #
    # Probe strategy:
    #   1. Attempt a write/delete probe on a privacy-gated domain.
    #   2. If the probe fails with permission text, print a highlighted FDA
    #      guide so later defaults-write failures are actionable.
    #   3. Continue activation either way so non-privacy-gated settings still
    #      converge in the same run.
    # -------------------------------------------------------------------------
    macos-check-privacy-permissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-preflight-privacy.sh" "${repoRoot}"
    '';

    # -------------------------------------------------------------------------
    # ensure-dev-directory (cross-host)
    # Ensures ~/dev exists before any dev-tree maintenance runs.
    #
    # WHY: separate activation: the directory itself is cross-host provisioning
    # state, while the macOS-only cleanup/indexing steps below are session-side
    # maintenance concerns.
    # -------------------------------------------------------------------------
    ensure-dev-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

    # -------------------------------------------------------------------------
    # macos-reload-dock
    # Restarts Dock so declarative Dock defaults take effect immediately.
    #
    # WHY: separate activation: Dock refresh is a UI cache reload, not dev-tree
    # maintenance. Keeping it independent avoids fake coupling with ~/dev work.
    # -------------------------------------------------------------------------
    macos-reload-dock = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-reload-dock-preference-state.sh"
    '';

    # -------------------------------------------------------------------------
    # macos-configure-finder-sidebar
    # Configure Finder favorites via mysides using a deterministic ordered list.
    # Avoids archive-rewrite workarounds; sidebar converges from activation.
    # NOTE: mysides writes to the SFLSharedFileList via com.apple.sharedfilelistd.
    # The daemon caches sidebar state; changes are fully visible in Finder only
    # after a macOS logout/reboot. The daemon restarts below provide a partial
    # in-session flush but a full restart is required for order to appear correctly.
    # Source: https://github.com/mosen/mysides
    macos-configure-finder-sidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-finder-sidebar.sh" ${lib.escapeShellArg (builtins.toJSON finderSidebar.finderSidebarManagedFavorites)} "${pkgs.jq}/bin/jq" "${pkgs.mysides}/bin/mysides" ${lib.escapeShellArg finderSidebar.finderSidebarExpectedOrder} ${toString finderSidebar.finderSidebarManagedCount}
    '';

    # -------------------------------------------------------------------------
    # relaunchDesktopServices
    # Single dedicated restart for desktop-related system processes (Finder,
    # SystemUIServer, WindowManager) after all configuration changes complete.
    # Uses launchctl kickstart for Finder (launchd-mediated, preserves window
    # state) and killall for SystemUIServer/WindowManager (no launchd service).
    # Re-applies sidebar favorites after restart since Finder may restore
    # default ordering.
    # -------------------------------------------------------------------------
    macos-relaunch-desktop-services = lib.hm.dag.entryAfter [ "macos-configure-finder-sidebar" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-relaunch-desktop-services.sh" ${lib.escapeShellArg (builtins.toJSON finderSidebar.finderSidebarManagedFavorites)} "${pkgs.jq}/bin/jq" "${pkgs.mysides}/bin/mysides"
    '';

    # -------------------------------------------------------------------------
    # verifyArchivingStack
    # Health check for archiving tools: verifies 7z CLI, Keka app registration,
    # and archive handler associations are functional after activation.
    # -------------------------------------------------------------------------
    macos-verify-archiving-stack =
      lib.hm.dag.entryAfter [ "macos-configure-launch-services" "installPackages" ]
        ''
          "${activationBundle}/src/scripts/packages/verify-archiving-stack.sh" "${pkgs.p7zip}/bin/7z"
        '';

    # -------------------------------------------------------------------------
    # macos-headless-display
    # Maintains exactly one BetterDisplay virtual screen named "HeadlessDisplay"
    # and keeps it connected for clamshell remote-desktop fallback.
    #
    # BetterDisplay free-tier constraint:
    #   Runtime `set -connected=on` can fail without Pro on some builds, even
    #   for virtual screens. To avoid paid-feature dependencies, this script
    #   repairs state by recreating the virtual screen with `-connected=on`
    #   instead of relying on connection toggles.
    #
    # Steps:
    #   1. Launch BetterDisplay in the background if it is not already running.
    #   2. Query BetterDisplay identifiers for `HeadlessDisplay`.
    #   3. If there are zero/multiple instances, rebuild to one clean instance.
    #   4. If the single instance exists but is disconnected, rebuild it.
    #
    # No-op if BetterDisplay is not installed.
    # -------------------------------------------------------------------------
    macos-configure-headless-display = lib.hm.dag.entryAfter [ "macos-install-nightlight" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-headless-display.sh"
    '';
  };

  # WHY: terminal-activations (last resort): Safari and accessibility defaults
  # require Full Disk Access (FDA), which is lost when running inside a sudo
  # process tree during darwin-rebuild switch.  Execute them in the user's
  # terminal context via the terminal-activations manifest so macOS TCC grants
  # are inherited.
  nucleus.terminalActivations = {
    macos-configure-passwords-defaults = {
      # WHY: terminal-activations (last resort): the PassKit daemon reverts
      # writes made during darwin-rebuild switch, so the live user-terminal
      # context is required for the .policy domain values to persist.
      command = "${activationBundle}/src/platforms/macOS/scripts/macos-configure-passwords-defaults.sh";
      order = 55;
    };
    macos-configure-safari-defaults = {
      command = "${activationBundle}/src/platforms/macOS/scripts/macos-configure-safari-defaults.sh";
      order = 50;
    };
    macos-configure-universal-access = {
      command = "${activationBundle}/src/platforms/macOS/scripts/macos-configure-universal-access.sh";
      order = 20;
    };
  };

  # Verify ALL home-manager-managed launchd agents are registered with launchd
  # after setupLaunchAgents runs.  On macOS 26, launchctl bootstrap can
  # spuriously return "Bootstrap failed: 5: Input/output error" — HM detects
  # this but never retries, and subsequent activations skip unchanged agents.
  home.activation.macos-ensure-launchagents = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    "${activationBundle}/src/platforms/macOS/scripts/macos-ensure-launchagents.sh" "$newGenPath"
  '';

  # --------------------------------------------------------------------------
  # gui-env-path
  # Single activation-time mechanism for macOS GUI environment variables.
  #
  # This step handles ALL GUI env var propagation at activation time:
  #   1. launchctl setenv NUCLEUS_REPO_ROOT — repo root for out-of-store symlinks
  #   2. launchctl setenv PATH — managed PATH with dedup (launchd-direct/XPC)
  #   3. launchctl setenv for all non-PATH vars from env-catalog (EDITOR,
  #      OLLAMA_HOST, etc.)
  #   4. sudo launchctl config user path — persistent per-user PATH for LaunchServices
  #      .app bundles (requires reboot on first set).
  #      KNOWN BROKEN: https://github.com/nix-darwin/nix-darwin/issues/1080 —
  #      `launchctl config` is unreliable or broken on many macOS versions;
  #      .app bundles launched via LaunchServices fall back to the default PATH.
  #
  # The gui-env LaunchAgent (below) provides login-time coverage before the
  # first activation runs.
  # --------------------------------------------------------------------------
  home.activation.macos-gui-env-path = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    "${activationBundle}/src/platforms/macOS/scripts/macos-set-gui-env-path.sh" \
      "${managedPaths.toShellPrependPath}" \
      "${managedPaths.toShellAppendPath}" \
      "${mkManagedDedupSet config.home.homeDirectory}" \
      ${lib.escapeShellArg envVars.macBookAllVars} \
      "${managedPaths.toLaunchctlConfigPath config.home.homeDirectory}"
  '';

  # --------------------------------------------------------------------------
  # GUI environment variable propagation LaunchAgent (gui-env) is defined in
  # ./launchd-agents.nix.  The gui-env-path activation step below re-applies all
  # vars on every nucleus-apply.
  # --------------------------------------------------------------------------
}
