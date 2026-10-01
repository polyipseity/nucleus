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
  mac-app-util,
  ...
}:
let
  overlay = (import ../../../modules/lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    effectiveUsername = config.home.username;
    inherit repoRoot;
  };

  linearmouseConfigFile = overlay.selectFile "linearmouse" "linearmouse.json";

  liveICloudDownloads = "${config.home.homeDirectory}/Library/Mobile Documents/com~apple~CloudDocs/Downloads";

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

  mkManagedDedupSet =
    prefix:
    builtins.concatStringsSep ":" (
      map (p: "${prefix}/${p}") (
        managedPaths.pathComponents.prepend ++ managedPaths.pathComponents.append
      )
    );

  chromeUTIs = [
    "public.html"
    "public.xhtml"
  ];

  kekaUTIs = [
    "public.zip-archive"
    "com.rarlab.rar-archive"
  ];

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

  dutiBin = "${pkgs.duti}/bin/duti";

  # Periodic heartbeat script for the BetterDisplay virtual screen.
  # Lives in the Nix store so the LaunchAgent ProgramArguments path is stable
  # across home-manager generations without a home.file symlink.
  # set +e at the top makes all operations fully soft-fail so launchd never
  # marks the agent as failed and throttles future invocations.
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

  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home.packages = [
    pkgs.mysides
  ];

  launchd.agents = launchdAgents.launchd.agents;

  home.file = {
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
    macos-configure-display-resolutions =
      lib.hm.dag.entryAfter [ "macos-configure-headless-display" ]
        ''
          "${activationBundle}/src/platforms/macOS/scripts/macos-display-resolutions.sh"
        '';

    macos-configure-input-config = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-input-config.sh"
    '';

    macos-reload-user-preference-state = lib.hm.dag.entryAfter [ "macos-configure-input-config" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-reload-user-preference-state.sh"
    '';

    # linearmouse-config
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    # Creates out-of-store symlinks for LinearMouse's runtime config files
    # pointing into the repository tree. Resolves the repo root at activation
    # time so the link survives repo relocations and rebuilds without stale
    # store paths.
    # check-suppress:config-method: method 1 (writable symlink) -- linearmouse/linearmouse.json deployed via linearmouse-config.sh
    macos-configure-linearmouse = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-linearmouse.sh" ${lib.escapeShellArg linearmouseConfigFile}
    '';

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

    # raycast-aliases
    # Raycast currently does not expose a dedicated language toggle for app-name
    # matching. On non-English macOS installations, localized display names can
    # therefore make English queries miss built-in apps.
    # Mitigation: publish a managed set of English-named .app symlink aliases
    # under ~/Applications/Nucleus App Aliases so Spotlight/Raycast can index
    # additional English tokens without changing the system UI language.
    macos-install-raycast-aliases = lib.hm.dag.entryAfter [ "macos-configure-launch-services" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-install-raycast-aliases.sh"
    '';

    # mac-app-util trampolines
    # Create Spotlight/Raycast-indexable .app wrappers for standalone GUI
    # binaries that lack .app bundles (e.g. Homebrew formula binaries like
    # Krokiet and Czkawka). Trampolines are AppleScript-compiled .app bundles
    # that launch the target binary, making them discoverable by Spotlight
    # and Raycast.
    # WHY: mac-app-util's HM module (sync-trampolines) only processes .app
    # bundles in ~/Applications/Home Manager Apps/. Homebrew binaries are not
    # .app bundles, so we call mktrampoline directly.
    # Source: https://github.com/hraban/mac-app-util
    macos-create-app-trampolines = lib.hm.dag.entryAfter [ "macos-install-raycast-aliases" ] ''
      _trampoline_dir="${config.home.homeDirectory}/Applications/Nucleus App Aliases"
      _mac_app_util="${mac-app-util.packages.${pkgs.stdenv.system}.default}/bin/mac-app-util"

      for _bin in "/opt/homebrew/bin/krokiet" "/opt/homebrew/bin/czkawka_gui"; do
        [ -x "$_bin" ] || continue
        _name="$(basename "$_bin")"
        "$_mac_app_util" mktrampoline "$_bin" "$_trampoline_dir/$_name.app"
      done
    '';

    # nightlight
    # Enables the macOS Night Shift schedule via the nightlight CLI tool and
    # applies a colour temperature of 50 % (roughly 4000 K).  Immediately
    # activates or deactivates the filter based on the current hour so the
    # display is always in the correct state right after an activation.
    # Schedule: 18:00 → 06:00 (nightlight schedule start uses default times).
    # No-op if nightlight is not installed.
    # Source: https://github.com/smudge/nightlight
    macos-install-nightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-install-nightlight.sh"
    '';

    # macos-configure-icloud-exclusions
    # Marks directories matching configured names with the com.apple.fileprovider
    # .ignore#P xattr to exclude them from iCloud sync. This prevents large
    # directories (e.g., node_modules, .venv) from syncing across devices.
    # Scope guard:
    #   1. Managed roots come from the centralized src/users/ registry.
    #   2. At evaluation time we discard any root outside Library/Mobile Documents.
    #   3. At runtime we recurse only inside those native iCloud directories.
    #   4. find -prune stops descent into excluded directories, keeping scans fast.
    # Configuration: excludedDirNames from src/users/ (e.g., ["node_modules"])
    # Source: https://developer.apple.com/documentation/fileprovider
    macos-configure-icloud-exclusions = lib.hm.dag.entryAfter [ "cloud-drives-setup" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-icloud-exclusions.sh" "${pkgs.jq}/bin/jq" "${pkgs.findutils}/bin/find" ${lib.escapeShellArg icloudExcludedDirsJson} ${lib.escapeShellArg icloudManagedRootsJson}
    '';

    # macos-check-privacy-permissions
    # Detects privacy-gated preference access problems early and emits an
    # explicit Full Disk Access remediation block so activation logs explain why
    # subsequent defaults writes may fail.
    # Probe strategy:
    #   1. Attempt a write/delete probe on a privacy-gated domain.
    #   2. If the probe fails with permission text, print a highlighted FDA
    #      guide so later defaults-write failures are actionable.
    #   3. Continue activation either way so non-privacy-gated settings still
    #      converge in the same run.
    macos-check-privacy-permissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-preflight-privacy.sh" "${repoRoot}"
    '';

    # ensure-dev-directory (cross-host)
    # Ensures ~/dev exists before any dev-tree maintenance runs.
    # WHY: separate activation: the directory itself is cross-host provisioning
    # state, while the macOS-only cleanup/indexing steps below are session-side
    # maintenance concerns.
    ensure-dev-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

    # macos-reload-dock
    # Restarts Dock so declarative Dock defaults take effect immediately.
    # WHY: separate activation: Dock refresh is a UI cache reload, not dev-tree
    # maintenance. Keeping it independent avoids fake coupling with ~/dev work.
    macos-reload-dock = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-reload-dock-preference-state.sh"
    '';

    macos-configure-finder-sidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-finder-sidebar.sh" ${lib.escapeShellArg (builtins.toJSON finderSidebar.finderSidebarManagedFavorites)} "${pkgs.jq}/bin/jq" "${pkgs.mysides}/bin/mysides" ${lib.escapeShellArg finderSidebar.finderSidebarExpectedOrder} ${toString finderSidebar.finderSidebarManagedCount}
    '';

    macos-relaunch-desktop-services = lib.hm.dag.entryAfter [ "macos-configure-finder-sidebar" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-relaunch-desktop-services.sh" ${lib.escapeShellArg (builtins.toJSON finderSidebar.finderSidebarManagedFavorites)} "${pkgs.jq}/bin/jq" "${pkgs.mysides}/bin/mysides"
    '';

    macos-verify-archiving-stack =
      lib.hm.dag.entryAfter [ "macos-configure-launch-services" "installPackages" ]
        ''
          "${activationBundle}/src/scripts/packages/verify-archiving-stack.sh" "${pkgs.p7zip}/bin/7z"
        '';

    macos-configure-headless-display = lib.hm.dag.entryAfter [ "macos-install-nightlight" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-headless-display.sh"
    '';

    # macos-generate-sf-symbols
    # Regenerates the SF Symbols name list from the macOS SFSymbols framework
    # into the USER root's state dir. The list used to be a committed 10,943-line
    # data file; generating it instead keeps it in step with the installed macOS
    # and keeps generated data out of the repository. The sf-symbols skill greps
    # the generated file.
    # WHY: /usr/bin/plutil is a macOS system binary with no nixpkgs attribute
    #   (nixpkgs.aarch64-darwin lacks `plutil`), so it is passed as its stable
    #   absolute path; grep, sort, and cmp are store paths.
    macos-generate-sf-symbols = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-generate-sf-symbols.sh" "/usr/bin/plutil" "${pkgs.gnugrep}/bin/grep" "${pkgs.coreutils}/bin/sort" "${pkgs.diffutils}/bin/cmp"
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

  # gui-env-path
  # Single activation-time mechanism for macOS GUI environment variables.
  # This step handles ALL GUI env var propagation at activation time:
  #   1. launchctl setenv PATH — managed PATH with dedup (launchd-direct/XPC)
  #   2. launchctl setenv for all non-PATH vars from env-secrets (EDITOR,
  #      OLLAMA_HOST, etc.)
  #   3. sudo launchctl config user path — persistent per-user PATH for LaunchServices
  #      .app bundles (requires reboot on first set).
  #      KNOWN BROKEN: https://github.com/nix-darwin/nix-darwin/issues/1080 —
  #      `launchctl config` is unreliable or broken on many macOS versions;
  #      .app bundles launched via LaunchServices fall back to the default PATH.
  # NUCLEUS_REPO_ROOT is resolved from the system repo-root file at runtime,
  # not set via launchctl (the env var was removed from the catalog in commit
  # 01ebf5e8 to prevent Nix store path poisoning).
  # The gui-env LaunchAgent (below) provides login-time coverage before the
  # first activation runs.
  home.activation.macos-gui-env-path = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    "${activationBundle}/src/platforms/macOS/scripts/macos-set-gui-env-path.sh" \
      "${managedPaths.toShellPrependPath}" \
      "${managedPaths.toShellAppendPath}" \
      "${mkManagedDedupSet config.home.homeDirectory}" \
      ${lib.escapeShellArg envVars.macBookAllVars} \
      "${managedPaths.toLaunchctlConfigPath config.home.homeDirectory}"
  '';

}
