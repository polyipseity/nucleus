# macOS-only activation hooks and LaunchAgents.
{
  config,
  lib,
  pkgs,
  username,
  nucleusApps,
  users ? null,
  ...
}:
let
  # Activation scripts resolve the repo root from $NUCLEUS_REPO_ROOT (set by apply.sh
  # and forwarded through sudo), so out-of-store symlinks survive repo relocations
  # and rebuilds without stale store paths.  As a fallback, capture NUCLEUS_REPO_ROOT
  # at eval time (where the env var IS available) so home-manager activation,
  # which runs as the user and does not inherit the sudo-level env var, can still
  # locate the repo root.
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  liveICloudDownloads = "${config.home.homeDirectory}/Library/Mobile Documents/com~apple~CloudDocs/Downloads";

  # Sub-module imports extracted from this file for focused maintainability.
  finderSidebar = import ./macos/finder-sidebar.nix { inherit config lib pkgs; };
  preferenceGc = import ./macos/preference-gc.nix { inherit config lib pkgs; };

  # Cached imports for all env-var-related callsites below.
  # managed-paths.nix for PATH components; env-catalog.nix for catalog/resolution.
  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVars = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  # ── Managed dirs dedup SET helper ──────────────────────────────────
  # Returns a colon-joined string of ALL managed dirs (both prepend and
  # append) for use as a case-pattern LOOKUP SET when stripping stale
  # entries from the current PATH before re-adding them.
  # This joins prepend+append as a SET for dedup — NOT as a PATH ordering.
  # The order within the returned string is irrelevant; only membership
  # matters.  The prefix argument is "${config.home.homeDirectory}" for
  # the activation script (build-time eval) or "$HOME" for the launchd
  # agent (runtime shell expansion).
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
  # the inline computation in configureICloudExclusions to keep the activation
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

  # fdaWarningFunction extracted to src/scripts/lib/macos-fda-warning-lib.sh

  # Standalone script for the daily icloud-exclusions LaunchAgent.
  # Uses bash (from the Nix store) rather than /bin/sh because the array-based
  # find-predicate builder and process substitution (< <(...)) require bash
  # semantics that macOS /bin/sh (zsh in POSIX mode) does not provide.
  # Logic mirrors configureICloudExclusions so both paths stay in sync.
  # Source: https://developer.apple.com/documentation/fileprovider
  # Standalone launchd script: embeds the clean function definition (no Nix
  # placeholders, no env-var deps) and calls apply_exclusions with arguments.
  # builtins.readFile here embeds a pure function definition, not a token-filled
  # script, so the lib-file policy (no token substitution in lib content) holds.
  icloudExclusionsScript = pkgs.writeTextFile {
    name = "icloud-exclusions";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -eu
    ''
    + (builtins.readFile ../scripts/lib/macos-icloud-exclusions-lib.sh)
    + ''
      apply_exclusions "${pkgs.jq}/bin/jq" "${pkgs.findutils}/bin/find" ${lib.escapeShellArg icloudExcludedDirsJson} ${lib.escapeShellArg icloudManagedRootsJson}
    '';
  };

  betterdisplayHeartbeat = pkgs.writeShellScript "betterdisplay-heartbeat" (
    builtins.readFile ../scripts/hosts/MacBook/macos-betterdisplay-heartbeat.sh
  );

  # Wrapper script for the nix-index daily database rebuild LaunchAgent.
  # Lives in the Nix store so the ProgramArguments path is stable across
  # home-manager generations without a home.file symlink.
  #
  # A freshness check prevents a full rebuild on every home-manager switch:
  # the LaunchAgent is reloaded on each switch because its plist embeds the
  # Nix store derivation path (which changes per generation).  Skipping the
  # rebuild when the DB was updated within the past 6 days keeps normal
  # apply runs fast.
  nixIndexUpdate = pkgs.writeShellScript "nix-index-update" (
    builtins.replaceStrings [ "__NIX_INDEX_BIN__" ] [ "${pkgs.nix-index}/bin/nix-index" ] (
      builtins.readFile ../scripts/hosts/MacBook/macos-nix-index-update.sh
    )
  );

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

  # Single-pass find predicate for low-signal build/cache directories in ~/dev.
  # Precompute the expression in Nix so the launchd job shell stays readable.
  devSpotlightExcludedDirectoryFindExpression = builtins.concatStringsSep " -o " (
    map (directoryName: "-name ${lib.escapeShellArg directoryName}") devSpotlightExcludedDirectoryNames
  );

  # Daily Spotlight exclusion refresh for the mutable ~/dev tree.
  # Kept out of Home Manager activation because large worktrees can make a full
  # scan slow enough to noticeably delay `nix run .#apply` and bootstrap apply.
  devSpotlightExclusions = pkgs.writeShellScript "spotlight-exclusions" (
    builtins.replaceStrings
      [ "__DEV_SPOTLIGHT_FIND_EXPRESSION__" ]
      [ "${devSpotlightExcludedDirectoryFindExpression}" ]
      (builtins.readFile ../scripts/hosts/MacBook/macos-spotlight-exclusions.sh)
  );

  # Daily Finder metadata cleanup for ~/dev.
  # Kept out of Home Manager activation for the same reason as Spotlight marker
  # maintenance: deleting stale .DS_Store files can take noticeable time on a
  # large checkout and should not slow synchronous apply/bootstrap flows.
  devDsStoreGc = pkgs.writeShellScript "ds-store-gc" (
    builtins.readFile ../scripts/hosts/MacBook/macos-ds-store-gc.sh
  );

  gcWeekly = pkgs.writeShellScript "gc-weekly" (
    builtins.replaceStrings [ "__REPO_ROOT__" ] [ repoRoot ] (
      builtins.readFile ../scripts/services/gc-weekly.sh
    )
  );

  guiEnvAgent = pkgs.writeShellScript "gui-env" (
    builtins.replaceStrings
      [ "__NUCLEUS_PREPEND__" "__NUCLEUS_APPEND__" "__NUCLEUS_MANAGED_SET__" "__MACOS_ALL_VARS__" ]
      [
        managedPaths.toShellPrependPath
        managedPaths.toShellAppendPath
        (mkManagedDedupSet "$HOME")
        envVars.macOSAllVars
      ]
      (builtins.readFile ../scripts/hosts/MacBook/macos-gui-env.sh)
  );
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [
    preferenceGc.managedPreferencesGcScript
    pkgs.mysides
  ];

  home.file = {
    # Keep iCloud Downloads reachable from a short stable path without
    # replacing ~/Downloads itself.
    "Downloads/iCloud".source = config.lib.file.mkOutOfStoreSymlink liveICloudDownloads;
  };

  home.activation.unprotectDownloadsICloudSymlink = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/hosts/MacBook/macos-unprotect-downloads-icloud-symlink.sh}
  '';

  home.activation.protectDownloadsICloudSymlink = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${builtins.readFile ../scripts/hosts/MacBook/macos-protect-downloads-icloud-symlink.sh}
  '';

  home.activation = {
    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    # display-resolutions
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
    display-resolutions = lib.hm.dag.entryAfter [ "macos-headless-display" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-display-resolutions.sh}
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
    input-config = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-input-config.sh}
      ${builtins.readFile ../scripts/hosts/MacBook/macos-refresh-tiswitcher.sh}
    '';

    # -------------------------------------------------------------------------
    # reloadUserPreferenceState
    # Forces macOS to flush/reload user defaults after all managed defaults
    # writes and domain-specific hooks.  This minimizes "ghost" values staying
    # in memory until logout/login after a rebuild.
    # -------------------------------------------------------------------------
    reloadUserPreferenceState =
      lib.hm.dag.entryAfter [ "input-config" "safari-defaults" "universal-access-defaults" ]
        ''
          if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
            echo "macos: activateSettings -u failed; some preference updates may require relogin." >&2
          fi
        '';

    # -------------------------------------------------------------------------
    # linearmouse-config
    # Method 1 (writable symlink) — repo changes take effect without rebuild.
    # Creates out-of-store symlinks for LinearMouse's runtime config files
    # pointing into the repository tree. Resolves the repo root at activation
    # time so the link survives repo relocations and rebuilds without stale
    # store paths.
    # Method 1 (writable symlink): linearmouse/linearmouse.json deployed via linearmouse-config.sh
    # -------------------------------------------------------------------------
    linearmouse-config = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      export REPO_ROOT="${repoRoot}"
      ${builtins.readFile ../scripts/hosts/MacBook/macos-linearmouse-config.sh}
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
    macos-launch-services = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/lib/import-macos-launch-services-lib.sh}

      # Bundle identifiers sourced from app bundles + vendor docs:
      # - Chrome: com.google.chrome
      #   https://chromeenterprise.google/policies/
      # - Keka: com.aone.keka
      #   https://www.keka.io/en/
      # - VLC: org.videolan.vlc
      #   https://wiki.videolan.org/MacOS/
      register_handler "${dutiBin}" "com.google.chrome" ${builtins.concatStringsSep " " chromeUTIs}
      register_handler "${dutiBin}" "com.aone.keka" ${builtins.concatStringsSep " " kekaUTIs}
      register_handler "${dutiBin}" "org.videolan.vlc" ${builtins.concatStringsSep " " vlcUTIs}
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
    raycast-aliases = lib.hm.dag.entryAfter [ "macos-launch-services" ] ''
      ${builtins.readFile ../scripts/lib/import-symlink-hardening.sh}
      _ray_alias_dir="$HOME/Applications/Nucleus App Aliases"
      mkdir -p "$_ray_alias_dir"
      ${builtins.readFile ../scripts/hosts/MacBook/macos-raycast-aliases.sh}
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
    nightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-nightlight.sh}
    '';

    # -------------------------------------------------------------------------
    # configureICloudExclusions
    # Marks directories matching configured names with the com.apple.fileprovider
    # .ignore#P xattr to exclude them from iCloud sync. This prevents large
    # directories (e.g., node_modules, .venv) from syncing across devices.
    #
    # Scope guard:
    #   1. Managed roots come from the centralized users.json registry.
    #   2. At evaluation time we discard any root outside Library/Mobile Documents.
    #   3. At runtime we recurse only inside those native iCloud directories.
    #   4. find -prune stops descent into excluded directories, keeping scans fast.
    #
    # Configuration: excludedDirNames from users.json (e.g., ["node_modules"])
    # Source: https://developer.apple.com/documentation/fileprovider
    # -------------------------------------------------------------------------
    configureICloudExclusions = lib.hm.dag.entryAfter [ "cloudDrivesSetup" ] ''
      ${builtins.readFile ../scripts/lib/import-macos-icloud-exclusions.sh}

      apply_exclusions "${pkgs.jq}/bin/jq" "${pkgs.findutils}/bin/find" ${lib.escapeShellArg icloudExcludedDirsJson} ${lib.escapeShellArg icloudManagedRootsJson}
    '';

    # -------------------------------------------------------------------------
    # preflightPrivacyPermissions
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
    preflightPrivacyPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-preflight-privacy.sh}
    '';

    # -------------------------------------------------------------------------
    # safari-defaults
    # Safari is sandboxed and stores preferences in a containerized domain that
    # `system.defaults.CustomUserPreferences` cannot always write during system
    # activation. Apply these settings from user activation instead so Safari
    # hardening remains declarative without breaking `darwin-rebuild switch`.
    # -------------------------------------------------------------------------
    safari-defaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] (
      ''
        ${builtins.readFile ../scripts/lib/import-macos-fda-warning.sh}
        fda_warning_emitted=0
        print_fda_warning "protected Safari preferences"
      ''
      + ''
        ${builtins.readFile ../scripts/hosts/MacBook/macos-safari-defaults.sh}
      ''
    );

    # -------------------------------------------------------------------------
    # universal-access-defaults
    # Accessibility defaults are user/session scoped and may be protected from
    # system-level defaults writes during `darwin-rebuild`. Apply them from the
    # user activation phase to keep accessibility intent without system errors.
    # -------------------------------------------------------------------------
    universal-access-defaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] (
      ''
        ${builtins.readFile ../scripts/lib/import-macos-fda-warning.sh}
        fda_warning_emitted=0
        print_fda_warning "Accessibility preferences"
      ''
      + ''
        ${builtins.readFile ../scripts/hosts/MacBook/macos-universal-access-defaults.sh}
      ''
    );

    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    # provisionDevDirectory
    # Ensures ~/dev exists before any dev-tree maintenance runs.
    #
    # WHY separate activation: the directory itself is cross-host provisioning
    # state, while the macOS-only cleanup/indexing steps below are session-side
    # maintenance concerns.
    # -------------------------------------------------------------------------
    provisionDevDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

    # -------------------------------------------------------------------------
    # reloadDockPreferenceState
    # Restarts Dock so declarative Dock defaults take effect immediately.
    #
    # WHY separate activation: Dock refresh is a UI cache reload, not dev-tree
    # maintenance. Keeping it independent avoids fake coupling with ~/dev work.
    # -------------------------------------------------------------------------
    reloadDockPreferenceState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-refresh-dock.sh}
    '';

    # -------------------------------------------------------------------------
    # configureFinderSidebar
    # Configure Finder favorites via mysides using a deterministic ordered list.
    # Avoids archive-rewrite workarounds; sidebar converges from activation.
    # NOTE: mysides writes to the SFLSharedFileList via com.apple.sharedfilelistd.
    # The daemon caches sidebar state; changes are fully visible in Finder only
    # after a macOS logout/reboot. The daemon restarts below provide a partial
    # in-session flush but a full restart is required for order to appear correctly.
    # Source: https://github.com/mosen/mysides
    configureFinderSidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${builtins.readFile ../scripts/lib/import-macos-finder-sidebar.sh}

      _finder_favorites_json='${builtins.toJSON finderSidebar.finderSidebarManagedFavorites}'
      _finder_jq_bin="${pkgs.jq}/bin/jq"
      _finder_mysides_bin="${pkgs.mysides}/bin/mysides"
      _finder_expected_order="${finderSidebar.finderSidebarExpectedOrder}"
      _finder_managed_count="${toString finderSidebar.finderSidebarManagedCount}"

      finder_configure_sidebar "$_finder_favorites_json" "$_finder_jq_bin" "$_finder_mysides_bin" "$_finder_expected_order" "$_finder_managed_count"
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
    relaunchDesktopServices = lib.hm.dag.entryAfter [ "configureFinderSidebar" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-refresh-desktop-services.sh}

      ${builtins.readFile ../scripts/lib/import-macos-finder-sidebar.sh}

      _finder_favorites_json='${builtins.toJSON finderSidebar.finderSidebarManagedFavorites}'
      _finder_jq_bin="${pkgs.jq}/bin/jq"
      _finder_mysides_bin="${pkgs.mysides}/bin/mysides"

      if [ -x "$_finder_mysides_bin" ]; then
        finder_reconcile_best_effort "$_finder_favorites_json" "$_finder_jq_bin" "$_finder_mysides_bin"
      fi
    '';

    # -------------------------------------------------------------------------
    # verifyArchivingStack
    # Health check for archiving tools: verifies 7z CLI, Keka app registration,
    # and archive handler associations are functional after activation.
    # -------------------------------------------------------------------------
    verifyArchivingStack = lib.hm.dag.entryAfter [ "macos-launch-services" "installPackages" ] ''
      # Verify 7z CLI is available and functional using direct Nix store path.
      # Do not rely on PATH lookup since Home Manager activation runs in a minimal
      # shell that may not have nix-darwin system package paths available yet.
      seven_z_exe="${pkgs.p7zip}/bin/7z"
      if [ ! -x "$seven_z_exe" ]; then
        echo "macos: warning — 7z binary not found at $seven_z_exe; archive extraction may fail." >&2
      elif ! "$seven_z_exe" --help >/dev/null 2>&1; then
        echo "macos: warning — 7z exists but --help failed; archive handling may be broken." >&2
      fi

      # Verify Keka application is installed and registered.
      if [ ! -d "/Applications/Keka.app" ]; then
        echo "macos: warning — Keka.app not found in /Applications; GUI archiving unavailable." >&2
      fi
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
    macos-headless-display = lib.hm.dag.entryAfter [ "nightlight" ] ''
      ${builtins.readFile ../scripts/hosts/MacBook/macos-headless-display.sh}
    '';
  };

  # --------------------------------------------------------------------------
  # Weekly garbage collection LaunchAgent
  # Performs bounded GC on every Sunday at noon to reclaim stale VM
  # artifacts, build outputs, and tool caches that accumulate across weeks.
  launchd.agents."gc-weekly" = {
    enable = true;
    config = {
      Label = "local.gc-weekly";
      ProgramArguments = [ "${gcWeekly}" ];
      # Do not run on every agent reload during apply/bootstrap apply; weekly
      # Sunday maintenance at noon is sufficient for accumulated artifact cleanup.
      RunAtLoad = false;
      StartCalendarInterval = [
        {
          Hour = 12;
          Minute = 0;
          Weekday = 0; # Sunday (0 = Sunday, 1 = Monday, ..., 6 = Saturday)
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
    enable = true;
    config = {
      Label = "local.betterdisplay-heartbeat";
      ProgramArguments = [ "${betterdisplayHeartbeat}" ];
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
  # `.DS_Store` cleanup and Spotlight exclusion markers only make sense on
  # macOS because both mechanisms are Finder/Spotlight-specific filesystem
  # conventions. Keep them as background launchd jobs instead of activation
  # hooks so `nix run .#apply` and bootstrap apply stay synchronous only for
  # configuration work that must happen immediately.
  # --------------------------------------------------------------------------
  launchd.agents."ds-store-gc" = {
    enable = true;
    config = {
      Label = "local.ds-store-gc";
      ProgramArguments = [ "${devDsStoreGc}" ];
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
    enable = true;
    config = {
      Label = "local.spotlight-exclusions";
      ProgramArguments = [ "${devSpotlightExclusions}" ];
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
    enable = true;
    config = {
      Label = "local.nix-index-update";
      ProgramArguments = [ "${nixIndexUpdate}" ];
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
  # switch.  configureICloudExclusions handles the immediate first-run case;
  # this agent provides drift correction between activations.
  # RunAtLoad = false because the activation hook already runs on every apply.
  # --------------------------------------------------------------------------
  launchd.agents."icloud-exclusions" = {
    enable = true;
    config = {
      Label = "local.icloud-exclusions";
      ProgramArguments = [ "${icloudExclusionsScript}" ];
      # Do not run on every agent reload during apply/bootstrap apply; the
      # activation hook (configureICloudExclusions) runs synchronously during
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
    enable = true;
    config = {
      Label = "local.service-watchdog-user";
      ProgramArguments = [
        "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog"
        "--domain"
        "user"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/nucleus/service-watchdog/stdout.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/nucleus/service-watchdog/stderr.log";
      EnvironmentVariables = {
        NUCLEUS_SERVICES_JSON = builtins.path {
          path = ./services.json;
          name = "nucleus-services-json-user";
        };
        NUCLEUS_REPO_ROOT = builtins.getEnv "NUCLEUS_REPO_ROOT";
      };
    };
  };

  # Verify ALL home-manager-managed launchd agents are registered with launchd
  # after setupLaunchAgents runs.  On macOS 26, launchctl bootstrap can
  # spuriously return "Bootstrap failed: 5: Input/output error" — HM detects
  # this but never retries, and subsequent activations skip unchanged agents.
  home.activation."ensure-launchagents" = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    ${builtins.readFile ../scripts/hosts/MacBook/macos-ensure-launchagents.sh}
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
  home.activation."gui-env-path" = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] (
    builtins.replaceStrings
      [
        "__MANAGED_PREPEND_PATH__"
        "__MANAGED_APPEND_PATH__"
        "__MANAGED_DEDUP_SET__"
        "__MACOS_ALL_VARS__"
        "__MANAGED_LAUNCHCTL_CONFIG_PATH__"
      ]
      [
        managedPaths.toShellPrependPath
        managedPaths.toShellAppendPath
        (mkManagedDedupSet config.home.homeDirectory)
        envVars.macOSAllVars
        (managedPaths.toLaunchctlConfigPath config.home.homeDirectory)
      ]
      (builtins.readFile ../scripts/hosts/MacBook/macos-gui-env-path.sh)
  );

  # --------------------------------------------------------------------------
  # GUI environment variable propagation LaunchAgent (macOS-only)
  # macOS maintains separate shell (user/<uid>/) and GUI (gui/<uid>/) launchd
  # domains.  Shell sessionVariables set via home.sessionVariables never cross
  # into the GUI domain.  This agent calls launchctl setenv for every variable
  # that GUI applications (Obsidian, VS Code, oterm, etc.) need, providing
  # login-time coverage before the first activation.
  #
  # The var list for non-PATH vars is generated from the centralized catalog
  # — see src/modules/lib/env-catalog.nix (macOSAllVars).  All vars with a macOS
  # value (both user and non-user) are included — safe because macOS launchd
  # GUI domains are per-user.
  #
  # This is a one-shot script (no loop) — launchctl setenv values persist in
  # the GUI domain until explicitly changed or reboot.  The gui-env-path
  # activation step re-applies all vars on every nucleus-apply.
  # --------------------------------------------------------------------------
  launchd.agents."gui-env" = {
    enable = true;
    config = {
      Label = "local.gui-env";
      ProgramArguments = [ "${guiEnvAgent}" ];
      # One-shot at login; gui-env-path activation step covers subsequent applies.
      RunAtLoad = true;
    };
  };
}
