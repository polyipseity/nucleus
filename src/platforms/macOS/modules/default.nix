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

  # macOS LaunchAgents, imported as a fragment and merged into the
  # isDarwin-guarded config below.
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

  # Periodic heartbeat script for the BetterDisplay virtual screen. The Nix
  # store path keeps the LaunchAgent ProgramArguments stable across home-manager
  # generations, and set +e makes every operation soft-fail so launchd never
  # throttles the agent.
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
    # WHY not the HM module: sync-trampolines only processes .app bundles in
    # ~/Applications/Home Manager Apps/, and Homebrew binaries are not bundles.
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
    # Marks matching directories with the com.apple.fileprovider .ignore#P xattr
    # so they stay out of iCloud sync.
    # Scope guard: roots come from the src/users/ registry, evaluation discards
    # anything outside Library/Mobile Documents, recursion stays inside those
    # directories, and find -prune keeps the scan fast. Names come from
    # src/users/.
    # Source: https://developer.apple.com/documentation/fileprovider
    macos-configure-icloud-exclusions = lib.hm.dag.entryAfter [ "cloud-drives-setup" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-icloud-exclusions.sh" "${pkgs.jq}/bin/jq" "${pkgs.findutils}/bin/find" ${lib.escapeShellArg icloudExcludedDirsJson} ${lib.escapeShellArg icloudManagedRootsJson}
    '';

    # macos-check-privacy-permissions
    # Probe a privacy-gated domain, print the FDA guide when the probe hits
    # permission text, and continue either way so ungated settings still
    # converge in the same run.
    macos-check-privacy-permissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-configure-preflight-privacy.sh" "${repoRoot}"
    '';

    # WHY separate from ~/dev: the directory is cross-host provisioning state,
    # while the macOS-only cleanup and indexing steps are session-side work.
    ensure-dev-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

    # WHY separate from ~/dev: a Dock refresh is a UI cache reload, and coupling
    # it to dev-tree work would be fake.
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
    # WHY generate the SF Symbols list: the committed 10,943-line data file
    # drifted from the installed macOS, and generated data does not belong in
    # the repository. The sf-symbols skill greps the generated file.
    # WHY /usr/bin/plutil: it is a macOS system binary with no nixpkgs
    # attribute (nixpkgs.aarch64-darwin lacks `plutil`), so it is passed as its
    # stable absolute path; grep, sort, and cmp are store paths.
    macos-generate-sf-symbols = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/platforms/macOS/scripts/macos-generate-sf-symbols.sh" "/usr/bin/plutil" "${pkgs.gnugrep}/bin/grep" "${pkgs.coreutils}/bin/sort" "${pkgs.diffutils}/bin/cmp"
    '';
  };

  # WHY terminal-activations (last resort): Full Disk Access is lost inside the
  # sudo process tree of darwin-rebuild switch, so these run in the user's
  # terminal context where the TCC grant is inherited.
  nucleus.terminalActivations = {
    macos-configure-passwords-defaults = {
      # WHY terminal-activations (last resort): the PassKit daemon reverts writes
      # made during darwin-rebuild switch, so the .policy domain values only
      # persist from a live user-terminal context.
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
  # Single activation-time mechanism for macOS GUI environment variables:
  # launchctl setenv PATH with dedup, launchctl setenv for every non-PATH var
  # from env-secrets (EDITOR, OLLAMA_HOST, and so on), and sudo launchctl config
  # user path for the persistent per-user LaunchServices PATH.
  # KNOWN BROKEN: nix-darwin issue 1080. `launchctl config` is unreliable on
  # many macOS versions, so .app bundles launched via LaunchServices fall back
  # to the default PATH.
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
