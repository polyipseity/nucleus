# modules/macos.nix — macOS-only Home Manager activation hooks and LaunchAgents.
#
# Guards the entire module with lib.mkIf pkgs.stdenv.isDarwin so it is a no-op
# on Linux hosts even though home.nix imports it unconditionally.
#
# Activation order (Home Manager DAG):
#   writeBoundary / linkGeneration
#     → clearDesktop, configureInputAndSiri, configureSystemHardening
#     → preflightPrivacyPermissions
#       → configureSafariDefaults, configureUniversalAccessDefaults
#       → reloadUserPreferenceState
#     → configureLaunchServices, configureNightlight
#       → ensureHeadlessDisplay
#         → configureDisplayResolutions
#           → displayHostManualInstructions
#
# LaunchAgents managed by this module:
#   local.betterdisplay-heartbeat — polls HeadlessDisplay every 30 s and
#     reconnects it if BetterDisplay drops the virtual screen connection.
#   local.nix-index-update — rebuilds the nix-index file database weekly
#     (Sunday 00:00) and on every agent load; a freshness check makes
#     reloads a fast no-op when the DB was updated within the past 6 days.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The canonical live checkout path is ~/dev/nucleus.  Use out-of-store
  # symlinks so app-managed config writes land in the mutable working tree
  # instead of a read-only Nix store snapshot.
  liveRepoRoot = "${config.home.homeDirectory}/dev/nucleus";
  liveICloudDownloads = "${config.home.homeDirectory}/Library/Mobile Documents/com~apple~CloudDocs/Downloads";
  liveLinearmouseConfig = "${liveRepoRoot}/src/modules/configs/linearmouse/linearmouse.json";

  # Domains intentionally reset before each Home Manager write pass so stale
  # manual overrides do not survive forever in ~/Library/Preferences.
  #
  # This list mirrors domains explicitly managed by this repository across:
  #   - system.defaults typed options (dock/finder/screencapture/trackpad/...)
  #   - system.defaults.CustomUserPreferences payloads
  #   - user activation defaults hooks (Safari/universalaccess/symbolichotkeys)
  #
  # Keep this list alphabetically sorted for easy drift reviews.
  resetUserPreferenceDomains = [
    "NSGlobalDomain"
    "com.apple.ActivityMonitor"
    "com.apple.AdLib"
    "com.apple.AppleMultitouchTrackpad"
    "com.apple.BezelServices"
    "com.apple.CloudDocs"
    "com.apple.HIToolbox"
    "com.apple.LaunchServices"
    "com.apple.Photos"
    "com.apple.Safari"
    "com.apple.Siri"
    "com.apple.SoftwareUpdate"
    "com.apple.Spotlight"
    "com.apple.SubmitDiagInfo"
    "com.apple.TextEdit"
    "com.apple.TextInput.Kybd"
    "com.apple.TextInputMenu"
    "com.apple.VoiceMemos"
    "com.apple.WindowManager"
    "com.apple.assistant.support"
    "com.apple.commerce"
    "com.apple.controlcenter"
    "com.apple.desktopservices"
    "com.apple.dock"
    "com.apple.finder"
    "com.apple.iokit.AmbientLightSensor"
    "com.apple.loginwindow"
    "com.apple.menuextra.clock"
    "com.apple.screencapture"
    "com.apple.screensaver"
    "com.apple.sidebarlists"
    "com.apple.speech.recognition.AppleSpeechRecognition.prefs"
    "com.apple.spaces"
    "com.apple.spotlight"
    "com.apple.symbolichotkeys"
    "com.apple.terminal"
    "com.apple.universalaccess"
    "com.apple.universalcontrol"
    "com.betterdisplay"
    "com.googlecode.iterm2"
  ];

  # UTI list for Chrome: set as the default handler for HTML and XHTML documents.
  chromeUTIs = [
    "public.html"
    "public.xhtml"
  ];

  # UTI list for Keka: covers 7z, RAR, and ZIP archive formats so that opening
  # any archive file launches Keka for graphical extraction/creation.
  kekaUTIs = [
    "public.zip-archive"
    "com.rarlab.rar-archive"
  ];

  # UTI list for VLC: covers the full range of video, audio, and playlist
  # formats that VLC supports so that double-clicking any media file opens VLC.
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
  betterdisplayHeartbeat = pkgs.writeShellScript "betterdisplay-heartbeat" ''
    set +e  # heartbeat is fully soft-fail; never abort on individual check failure

    BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    BD_APP="/Applications/BetterDisplay.app"
    DISPLAY_NAME="HeadlessDisplay"

    # No-op if BetterDisplay is not installed.
    [ -f "$BD_BIN" ] || exit 0

    # Ensure BetterDisplay is running before issuing CLI commands.
    if ! /usr/bin/pgrep -xq "BetterDisplay" 2>/dev/null; then
      /usr/bin/open -g -a "$BD_APP" || true
      /bin/sleep 5
    fi

    # Check connection state; soft-fail by treating any CLI error as unknown.
    connected_state="$("$BD_BIN" get -name="$DISPLAY_NAME" -connected)" || true

    # No-op if already connected.
    [ "$connected_state" = "on" ] && exit 0

    # Virtual screen is disconnected or status is unknown.  Try the lightweight
    # set -connected=on toggle first; it is free-tier-compatible for virtual
    # screens (Pro gating applies only to physical display connection toggles).
    # If the toggle fails, fall back to a discard-and-recreate using the same
    # parameters as ensureHeadlessDisplay so the virtual screen specification
    # stays consistent across both code paths.
    if ! "$BD_BIN" set -name="$DISPLAY_NAME" -connected=on; then
      tag_ids="$("$BD_BIN" get -identifiers -name="$DISPLAY_NAME" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)" || true
      for tag_id in $tag_ids; do
        "$BD_BIN" discard -tagID="$tag_id" || true
      done
      "$BD_BIN" create \
        -type=VirtualScreen \
        -virtualScreenName="$DISPLAY_NAME" \
        -aspectWidth=16 \
        -aspectHeight=10 \
        -multiplierStep=160 \
        -virtualScreenHiDPI=on \
        -connected=on || true
    fi
  '';

  # Wrapper script for the nix-index weekly database rebuild LaunchAgent.
  # Lives in the Nix store so the ProgramArguments path is stable across
  # home-manager generations without a home.file symlink.
  #
  # A freshness check prevents a full rebuild on every home-manager switch:
  # the LaunchAgent is reloaded on each switch because its plist embeds the
  # Nix store derivation path (which changes per generation).  Skipping the
  # rebuild when the DB was updated within the past 6 days keeps normal
  # apply runs fast.
  nixIndexUpdate = pkgs.writeShellScript "nix-index-update" ''
    db_file="$HOME/.cache/nix-index/files"

    # Skip rebuild when the DB file exists and was modified within the last
    # 6 days.  find -mtime +6 matches files with modification time strictly
    # greater than 6x24 h ago; empty output means the file is still fresh.
    if [ -f "$db_file" ] && [ -z "$(find "$db_file" -mtime +6)" ]; then
      exit 0
    fi

    exec ${pkgs.nix-index}/bin/nix-index
  '';

  # Pinned iTerm2 zsh shell integration script placed at
  # ~/.iterm2_shell_integration.zsh via home.file.  The script enables command
  # marks, command history, directory reporting, and in-terminal image display
  # in iTerm2 sessions; it is sourced at zsh startup via programs.zsh.initContent.
  # Update sha256 when iTerm2 publishes a new integration revision:
  #   nix-prefetch-url https://iterm2.com/shell_integration/zsh
  iterm2ZshIntegration = pkgs.fetchurl {
    url = "https://iterm2.com/shell_integration/zsh";
    sha256 = "0yhfnaigim95sk1idrc3hpwii8hfhjl5m3lyc0ip3vi1a9npq0li";
  };

  # Manual drift-reset helper for managed macOS preference domains.
  # This is intentionally a user-invoked command instead of an automatic
  # activation phase so destructive purge operations cannot race with
  # writeBoundary defaults application.
  managedPreferencesPurgeScript = pkgs.writeShellScriptBin "purge-managed-user-preferences" ''
    set -eu

    # Verify Nix store integrity before running destructive preference cleanup.
    # If verification fails we skip purge so an unrelated store issue cannot be
    # compounded by deleting user preference state in the same maintenance run.
    if ! ${pkgs.nix}/bin/nix-store --verify --check-contents >/dev/null 2>&1; then
      echo "macos: store integrity check failed; skipping managed preference purge for safety." >&2
      exit 0
    fi

    prefs_root="$HOME/Library/Preferences"
    byhost_root="$prefs_root/ByHost"

    purge_domain_variants() {
      domain="$1"
      domain_variants="$domain"

      if [ "$domain" = "NSGlobalDomain" ]; then
        domain_variants="$domain .GlobalPreferences"
      fi

      for variant in $domain_variants; do
        # Clear in-memory registration first, then remove persisted payloads.
        /usr/bin/defaults delete "$variant" >/dev/null 2>&1 || true

        if [ -d "$prefs_root" ]; then
          /usr/bin/find "$prefs_root" -maxdepth 1 -type f -name "$variant.plist" -delete
        fi

        if [ -d "$byhost_root" ]; then
          /usr/bin/find "$byhost_root" -maxdepth 1 -type f -name "$variant.*.plist" -delete
        fi
      done
    }

    for domain in ${builtins.concatStringsSep " " resetUserPreferenceDomains}; do
      purge_domain_variants "$domain"
    done

    /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
    /bin/sleep 2

    echo "Managed preference domains purged. Run your apply flow to re-assert declarative defaults."
  '';

  # Keep displayHostManualInstructions as the final user-visible activation
  # step.
  # Any new activation entry added to this module should be appended here so
  # manual instructions remain the last script to run.
  displayHostManualInstructionDeps = [
    "agentsSkills"
    "agentsSymlink"
    "checkFilesChanged"
    "checkLinkTargets"
    "clearDesktop"
    "cloudDrivesICloudRefresh"
    "cloudDrivesSetup"
    "configureDisplayResolutions"
    "configureFinderSidebar"
    "configureInputAndSiri"
    "configureLaunchServices"
    "configureRaycastApplicationAliases"
    "configureNightlight"
    "configureObsidianSettings"
    "configureSafariDefaults"
    "configureSystemHardening"
    "configureUniversalAccessDefaults"
    "ensureHeadlessDisplay"
    # gitIdentityFromSops, gpgImport, sshKeyAdopt, and verifySecretDecryption
    # are defined in secrets.nix (shared module) but run as Home Manager
    # activations on this host; they must all complete before the manual
    # instructions are printed so the final output is complete.
    "gitIdentityFromSops"
    "gitIgnoreAssemble"
    "gpgImport"
    "installBunPackages"
    "installPackages"
    "installPwshScriptAnalyzer"
    "linkGeneration"
    "onFilesChange"
    "preflightPrivacyPermissions"
    "refreshFinderServices"
    "reloadUserPreferenceState"
    "setupLaunchAgents"
    "sops-nix"
    "sshKeyAdopt"
    # Keep exact activation name casing aligned with agents.nix
    # (`syncClawHubSkills`) so manual instructions remain the terminal node.
    "syncClawHubSkills"
    "verifyArchivingStack"
    "verifySecretDecryption"
    "vsCodeExtensionBridge"
    "vsCodeSymlinks"
    "vsCodeWorkspaceTrust"
    "waitForSopsSecrets"
    "wallpaperProvision"
    "writeBoundary"
  ];
in
lib.mkIf pkgs.stdenv.isDarwin {
  assertions = [
    {
      assertion = config.nucleus.hostManualFile != null;
      message = "modules/macos.nix requires nucleus.hostManualFile to be set by the Darwin host entrypoint (for example ./MANUAL.md in src/hosts/macbook/default.nix).";
    }
  ];

  home.packages = [ managedPreferencesPurgeScript ];

  home.file = {
    # Place the pinned iTerm2 zsh shell integration script at the well-known
    # path that the sourcing guard in programs.zsh.initContent expects.
    # home.file replaces the symlink atomically on each home-manager switch so
    # the script version tracks the pinned hash in iterm2ZshIntegration above.
    ".iterm2_shell_integration.zsh".source = iterm2ZshIntegration;

    # Keep both LinearMouse runtime config paths pointed at the canonical
    # repo-backed JSON so app writes appear immediately as working-tree diffs.
    ".config/linearmouse/linearmouse.json".source =
      config.lib.file.mkOutOfStoreSymlink liveLinearmouseConfig;
    "Library/Application Support/linearmouse/linearmouse.json".source =
      config.lib.file.mkOutOfStoreSymlink liveLinearmouseConfig;

    # Keep iCloud Downloads reachable from a short stable path without
    # replacing ~/Downloads itself.
    "Downloads/iCloud".source = config.lib.file.mkOutOfStoreSymlink liveICloudDownloads;
  };

  # Source iTerm2 shell integration when the script is present.  The test-e
  # guard makes this a no-op in non-iTerm2 terminals (VS Code terminal, SSH,
  # Ghostty, etc.) where the iTerm2 escape sequences produce no useful output
  # and may be visible as raw control codes.
  programs.zsh.initContent = ''
    test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
  '';

  home.activation = {
    # -------------------------------------------------------------------------
    # clearDesktop
    # Restarts the three system UI processes that cache defaults values so that
    # settings written earlier in the activation chain take effect immediately
    # without requiring a full logout/reboot.
    #   Finder         — file manager and Desktop drawing
    #   WindowManager  — manages Spaces and Stage Manager
    #   SystemUIServer — menu-bar icons (clock, input source, etc.)
    # -------------------------------------------------------------------------
    clearDesktop = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      for proc in Finder SystemUIServer WindowManager; do
        if ! /usr/bin/killall "$proc"; then
          echo "macos: $proc was not running (or could not be restarted)." >&2
        fi
      done
    '';

    # -------------------------------------------------------------------------
    # configureDisplayResolutions
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
    configureDisplayResolutions = lib.hm.dag.entryAfter [ "ensureHeadlessDisplay" ] ''
      DP_BIN="/opt/homebrew/bin/displayplacer"

      if [ -x "$DP_BIN" ]; then
        FULL_LIST=$("$DP_BIN" list)

        # Locate the persistent ID of the built-in MacBook screen.
        PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/awk '
          /^Persistent screen id:/ { last_id=$4 }
          /Type: MacBook built in screen/ { print last_id; exit }
        ')

        # Fall back to the first listed display if the built-in label is absent.
        if [ -z "$PRIMARY_ID" ]; then
          PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/head -n 1 | /usr/bin/awk '{print $4}')
        fi

        # Read the mode 4 string for the primary display (native HiDPI mode).
        MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /^  mode 4:/ {
            sub(/^[ ]*mode 4: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

        # If mode 4 is not available, read whichever mode is currently active.
        if [ -z "$MODE4_STR" ]; then
          MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
            $0 ~ id { found=1 }
            found && /<-- current mode/ {
              sub(/^[ ]*mode [0-9]+: /, "");
              sub(/[ ]*<-- current mode/, "");
              print $0;
              exit;
            }
          ')
        fi

        # Apply the target mode on the primary display and refresh the list.
        if [ -n "$MODE4_STR" ]; then
          if ! "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR"; then
            echo "macos: failed to apply primary display mode with displayplacer." >&2
          fi
          /bin/sleep 1
          FULL_LIST=$("$DP_BIN" list)
        fi

        # Read the mode that is now active on the primary display to use as
        # the reference resolution for external monitors.
        TARGET_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /<-- current mode/ {
            sub(/^[ ]*mode [0-9]+: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

        # Extract width, height, and scaling flag from the target mode string.
        T_W=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:([0-9]+)x.*/\1/')
        T_H=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:[0-9]+x([0-9]+).*/\1/')
        T_SCALING=""
        if echo "$TARGET_STR" | /usr/bin/grep -q "scaling:on"; then
          T_SCALING="scaling:on"
        fi

        # For each external display, select the best matching mode and apply it.
        for ID in $(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/awk '{print $4}'); do
          if [ "$ID" = "$PRIMARY_ID" ]; then
            continue
          fi

          MODES=$(echo "$FULL_LIST" | /usr/bin/sed -n "/^Persistent screen id: $ID/,/^Persistent screen id:/p" | /usr/bin/grep "^  mode " | /usr/bin/sed 's/^  mode [0-9]*: //')
          # When the primary uses HiDPI scaling, restrict candidates to HiDPI modes.
          if [ -n "$T_SCALING" ]; then
            MODES=$(echo "$MODES" | /usr/bin/grep "scaling:on")
          fi

          # Pick the mode with the smallest height that is still ≥ target width
          # and ≤ target height (fits the same logical area, highest PPI wins).
          BEST_MODE=$(echo "$MODES" | /usr/bin/awk -v tw="$T_W" -v th="$T_H" '{ w=substr($0,index($0,"res:")+4); gsub(/[^0-9].*/,"",w); h=substr($0,index($0,"x")+1); gsub(/[^0-9].*/,"",h); if (w+0>=tw+0 && h+0<=th+0 && h+0>0) print w+0, h+0, $0 }' | /usr/bin/sort -n | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f3- | /usr/bin/sed 's/ <-- current mode$//')

          if [ -n "$BEST_MODE" ]; then
            if ! "$DP_BIN" "id:$ID $BEST_MODE"; then
              echo "macos: failed to apply mode '$BEST_MODE' to display id $ID." >&2
            fi
          fi
        done
      fi
    '';

    # -------------------------------------------------------------------------
    # configureInputAndSiri
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
    configureInputAndSiri = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>"; then
        echo "macos: failed to update symbolic hotkey 176." >&2
      fi

      if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
        echo "macos: activateSettings -u failed; input settings may apply on next login." >&2
      fi

      if ! /usr/bin/killall -HUP TISwitcher; then
        echo "macos: TISwitcher was not running (or could not be signaled)." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # reloadUserPreferenceState
    # Forces macOS to flush/reload user defaults after all managed defaults
    # writes and domain-specific hooks.  This minimizes "ghost" values staying
    # in memory until logout/login after a rebuild.
    # -------------------------------------------------------------------------
    reloadUserPreferenceState =
      lib.hm.dag.entryAfter
        [
          "configureInputAndSiri"
          "configureSafariDefaults"
          "configureUniversalAccessDefaults"
        ]
        ''
          if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
            echo "macos: activateSettings -u failed; some preference updates may require relogin." >&2
          fi
        '';

    # -------------------------------------------------------------------------
    # configureITerm2Settings was removed: `BootstrapDaemon = true` is now
    # handled declaratively in defaults.nix via
    # system.defaults.CustomUserPreferences."com.googlecode.iterm2".
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # configureLaunchServices
    # Registers default application handlers for file types using duti.
    # Running this in a Home Manager activation keeps the associations in sync
    # every time `home-manager switch` is run, which is necessary because
    # application (re)installs can reset handler registrations.
    #
    #   Chrome — handles all HTML/XHTML documents
    #   Keka   — handles .7z, .rar, and .zip archives
    #   VLC    — handles the complete set of audio/video UTIs defined above
    # -------------------------------------------------------------------------
    configureLaunchServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # register_handler BUNDLE_ID UTI [UTI ...]
      # Sets BUNDLE_ID as the default handler for each UTI across all roles.
      register_handler() {
        handler="$1"
        shift

        for uti in "$@"; do
          if ! "${dutiBin}" -s "$handler" "$uti" all; then
            echo "macos: failed to register LaunchServices handler $handler for UTI $uti." >&2
          fi
        done
      }

      register_handler "com.google.chrome" ${builtins.concatStringsSep " " chromeUTIs}
      register_handler "com.aone.keka" ${builtins.concatStringsSep " " kekaUTIs}
      register_handler "org.videolan.vlc" ${builtins.concatStringsSep " " vlcUTIs}
    '';

    # -------------------------------------------------------------------------
    # configureRaycastApplicationAliases
    # Raycast currently does not expose a dedicated language toggle for app-name
    # matching. On non-English macOS installations, localized display names can
    # therefore make English queries miss built-in apps.
    #
    # Mitigation: publish a managed set of English-named .app symlink aliases
    # under ~/Applications/Nucleus App Aliases so Spotlight/Raycast can index
    # additional English tokens without changing the system UI language.
    # -------------------------------------------------------------------------
    configureRaycastApplicationAliases = lib.hm.dag.entryAfter [ "configureLaunchServices" ] ''
      _ray_alias_dir="$HOME/Applications/Nucleus App Aliases"
      mkdir -p "$_ray_alias_dir"

      protect_alias_symlink() {
        _ray_alias_path="$1"
        if ! /usr/bin/chflags -h uchg "$_ray_alias_path"; then
          echo "raycast: warning — could not protect alias symlink $_ray_alias_path with uchg." >&2
        fi
      }

      unprotect_alias_symlink() {
        _ray_alias_path="$1"
        if ! /usr/bin/chflags -h nouchg "$_ray_alias_path"; then
          echo "raycast: warning — could not clear uchg from alias symlink $_ray_alias_path before update." >&2
        fi
      }

      ensure_alias() {
        _alias_name="$1"
        _target_app="$2"
        _alias_path="$_ray_alias_dir/$_alias_name"

        [ -e "$_target_app" ] || return 0

        if [ -L "$_alias_path" ]; then
          if [ "$(readlink "$_alias_path")" = "$_target_app" ]; then
            protect_alias_symlink "$_alias_path"
            return 0
          fi
          unprotect_alias_symlink "$_alias_path"
          rm "$_alias_path"
        elif [ -e "$_alias_path" ]; then
          echo "raycast: keeping unmanaged app alias path $_alias_path (not a symlink)." >&2
          return 0
        fi

        ln -s "$_target_app" "$_alias_path"
        protect_alias_symlink "$_alias_path"
      }

      ensure_alias "Books (English).app" "/System/Applications/Books.app"
      ensure_alias "Calculator (English).app" "/System/Applications/Calculator.app"
      ensure_alias "Calendar (English).app" "/System/Applications/Calendar.app"
      ensure_alias "Contacts (English).app" "/System/Applications/Contacts.app"
      ensure_alias "FaceTime (English).app" "/System/Applications/FaceTime.app"
      ensure_alias "Find My (English).app" "/System/Applications/FindMy.app"
      ensure_alias "Freeform (English).app" "/System/Applications/Freeform.app"
      ensure_alias "Home (English).app" "/System/Applications/Home.app"
      ensure_alias "Mail (English).app" "/System/Applications/Mail.app"
      ensure_alias "Maps (English).app" "/System/Applications/Maps.app"
      ensure_alias "Messages (English).app" "/System/Applications/Messages.app"
      ensure_alias "Music (English).app" "/System/Applications/Music.app"
      ensure_alias "Notes (English).app" "/System/Applications/Notes.app"
      ensure_alias "Photos (English).app" "/System/Applications/Photos.app"
      ensure_alias "Reminders (English).app" "/System/Applications/Reminders.app"
      ensure_alias "Safari (English).app" "/Applications/Safari.app"
      ensure_alias "TV (English).app" "/System/Applications/TV.app"
      ensure_alias "Weather (English).app" "/System/Applications/Weather.app"
    '';

    # -------------------------------------------------------------------------
    # configureNightlight
    # Enables the macOS Night Shift schedule via the nightlight CLI tool and
    # applies a colour temperature of 50 % (roughly 4000 K).  Immediately
    # activates or deactivates the filter based on the current hour so the
    # display is always in the correct state right after an activation.
    #
    # Schedule: 18:00 → 06:00 (nightlight schedule start uses default times).
    # No-op if nightlight is not installed.
    # -------------------------------------------------------------------------
    configureNightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [ -x "/opt/homebrew/bin/nightlight" ]; then
        if ! /opt/homebrew/bin/nightlight schedule start; then
          echo "macos: failed to configure Nightlight schedule." >&2
        fi

        if ! /opt/homebrew/bin/nightlight temp 50; then
          echo "macos: failed to set Nightlight temperature." >&2
        fi

        current_hour=$(date +%H)
        if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
          if ! /opt/homebrew/bin/nightlight on; then
            echo "macos: failed to enable Nightlight." >&2
          fi
        else
          if ! /opt/homebrew/bin/nightlight off; then
            echo "macos: failed to disable Nightlight." >&2
          fi
        fi
      fi
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
      echo "macos: checking macOS privacy permissions before defaults writes..." >&2

      print_fda_warning() {
        bold="$(printf '\033[1m')"
        red="$(printf '\033[31m')"
        reset="$(printf '\033[0m')"
        yellow="$(printf '\033[33m')"

        printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
        printf '%sNucleus detected that this terminal session lacks permission to modify protected user preferences.%s\n' "$yellow" "$reset" >&2
        printf '%s\n' "To fix this:" >&2
        printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
        printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
        printf '  3. Restart the terminal and run activation again\n' >&2
      }

      probe_domain="com.apple.universalaccess"
      probe_key="NucleusActivationProbe"
      if ! probe_err="$({
        /usr/bin/defaults write "$probe_domain" "$probe_key" -bool false
        /usr/bin/defaults delete "$probe_domain" "$probe_key"
      } 2>&1)"; then
        if printf '%s' "$probe_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
          print_fda_warning
        else
          echo "macos: privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes." >&2
        fi
      fi
    '';

    # -------------------------------------------------------------------------
    # configureSafariDefaults
    # Safari is sandboxed and stores preferences in a containerized domain that
    # `system.defaults.CustomUserPreferences` cannot always write during system
    # activation. Apply these settings from user activation instead so Safari
    # hardening remains declarative without breaking `darwin-rebuild switch`.
    # -------------------------------------------------------------------------
    configureSafariDefaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] ''
      fda_warning_emitted=0

      print_fda_warning() {
        if [ "$fda_warning_emitted" -eq 1 ]; then
          return
        fi

        bold="$(printf '\033[1m')"
        red="$(printf '\033[31m')"
        reset="$(printf '\033[0m')"
        yellow="$(printf '\033[33m')"

        printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
        printf '%sNucleus cannot write protected Safari preferences from this terminal session.%s\n' "$yellow" "$reset" >&2
        printf '%s\n' "To fix this:" >&2
        printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
        printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
        printf '  3. If already enabled, remove and re-add it, then restart the terminal\n' >&2

        fda_warning_emitted=1
      }

      set_safari_default() {
        key="$1"
        value="$2"
        value_type="$3"

        if ! write_err="$({ /usr/bin/defaults write com.apple.Safari "$key" "-$value_type" "$value"; } 2>&1)"; then
          if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
            print_fda_warning
            echo "macos: failed to set Safari key $key due to missing privacy authorization." >&2
          else
            echo "macos: failed to set Safari key $key ($write_err)." >&2
          fi
        fi
      }

      set_safari_default "AutoFillPasswords" "false" "bool"
      set_safari_default "IncludeDevelopMenu" "true" "bool"
      set_safari_default "IncludeInternalDebugMenu" "true" "bool"
    '';

    # -------------------------------------------------------------------------
    # configureUniversalAccessDefaults
    # Accessibility defaults are user/session scoped and may be protected from
    # system-level defaults writes during `darwin-rebuild`. Apply them from the
    # user activation phase to keep accessibility intent without system errors.
    # -------------------------------------------------------------------------
    configureUniversalAccessDefaults = lib.hm.dag.entryAfter [ "preflightPrivacyPermissions" ] ''
      fda_warning_emitted=0

      print_fda_warning() {
        if [ "$fda_warning_emitted" -eq 1 ]; then
          return
        fi

        bold="$(printf '\033[1m')"
        red="$(printf '\033[31m')"
        reset="$(printf '\033[0m')"
        yellow="$(printf '\033[33m')"

        printf '%s%sERROR: Full Disk Access Required%s\n' "$red" "$bold" "$reset" >&2
        printf '%sNucleus cannot write Accessibility preferences from this terminal session.%s\n' "$yellow" "$reset" >&2
        printf '%s\n' "To fix this:" >&2
        printf '  1. Open %sSystem Settings > Privacy & Security > Full Disk Access%s\n' "$bold" "$reset" >&2
        printf '  2. Toggle %sOn%s for your terminal emulator\n' "$bold" "$reset" >&2
        printf '  3. If already enabled, remove and re-add it, then restart the terminal\n' >&2

        fda_warning_emitted=1
      }

      set_default() {
        domain="$1"
        key="$2"
        value="$3"
        value_type="$4"
        yellow="$(printf '\033[33m')"
        bold="$(printf '\033[1m')"
        reset="$(printf '\033[0m')"

        if ! write_err="$({ /usr/bin/defaults write "$domain" "$key" "-$value_type" "$value"; } 2>&1)"; then
          if printf '%s' "$write_err" | /usr/bin/grep -Eqi 'Operation not permitted|Permission denied'; then
            print_fda_warning
            printf '%s![Permission Denied]%s Failed to set %s%s %s%s. Ensure Full Disk Access and Accessibility permissions are granted.\n' "$yellow" "$reset" "$bold" "$domain" "$key" "$reset" >&2
          else
            echo "macos: failed to set $domain $key ($write_err)." >&2
          fi
        fi
      }

      set_default "com.apple.universalaccess" "FontSizeCategory" "AX1" "string"
      set_default "com.apple.universalaccess" "cursorSize" "1.33" "float"
      set_default "com.apple.universalaccess" "reduceMotion" "false" "bool"
      set_default "com.apple.universalaccess" "reduceTransparency" "false" "bool"
      set_default "com.apple.universalaccess" "showWindowTitlebarIcons" "true" "bool"
    '';

    # -------------------------------------------------------------------------
    # configureSystemHardening
    # Applies Spotlight indexing suppression and dev-tree metadata cleanup;
    # requires a running user session (not available to system-level scripts).
    #
    #   .metadata_never_index files: tells Spotlight not to index well-known
    #   build artifact directories under ~/dev (node_modules, target, build,
    #   dist, etc.), reducing indexing CPU/disk overhead and avoiding Spotlight
    #   surfacing compiled binaries or cache files.
    #
    #   .DS_Store cleanup: removes Finder metadata files under ~/dev after each
    #   activation to keep Git worktrees cleaner. macOS cannot fully disable
    #   .DS_Store creation on local APFS/HFS+ volumes, so this is a compensating
    #   control for development paths.
    #
    #   Dock restart: applies any pending Dock pref changes (e.g. hot corners
    #   written declaratively via CustomUserPreferences."com.apple.dock") without
    #   requiring a full logout.
    #
    # Dock hot-corner disable (wdev-tl/tr/bl/br = 0) is now handled declaratively
    # in defaults.nix via system.defaults.CustomUserPreferences."com.apple.dock".
    # -------------------------------------------------------------------------
    configureSystemHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DEV_ROOT="$HOME/dev"
      if [ -d "$DEV_ROOT" ]; then
        # Place a .metadata_never_index sentinel inside every well-known build
        # artifact directory found under ~/dev so Spotlight skips them.
        for dir_name in ".gradle" ".next" ".turbo" ".venv" "__pycache__" "bin" "build" "dist" "incremental" "node_modules" "obj" "target" "venv" "vendor"; do
          if ! /usr/bin/find "$DEV_ROOT" -name "$dir_name" -type d -prune -exec touch "{}/.metadata_never_index" \;; then
            echo "macos: failed to mark one or more '$dir_name' directories as metadata_never_index." >&2
          fi
        done

        # Remove Finder metadata files from development trees to reduce
        # repository noise. This is safe/idempotent because Finder recreates
        # files on demand when folder-view state changes.
        if ! /usr/bin/find "$DEV_ROOT" -name ".DS_Store" -type f -delete; then
          echo "macos: failed to remove one or more .DS_Store files under ~/dev." >&2
        fi
      else
        mkdir -p "$DEV_ROOT"
      fi

      if ! /usr/bin/killall Dock; then
        echo "macos: Dock was not running (or could not be restarted)." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # configureFinderSidebar
    # Enforce an exact Finder sidebar Favourites list by removing all current
    # user-managed entries and re-adding the canonical set in declared order.
    #
    # Uses sfltool (macOS built-in) against the FavoriteItems shared file list.
    # System-managed entries such as AirDrop and Recents live outside this list
    # and are unaffected.
    #
    # WHY remove-all then add: sfltool has no reorder command; the only way to
    # guarantee both the exact set and the exact order is a full replace on
    # every activation.
    # -------------------------------------------------------------------------
    configureFinderSidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _sflt_list="com.apple.LSSharedFileList.FavoriteItems"

      # Remove all current user-managed sidebar items.
      # sfltool list outputs TAB-separated "Name<TAB>file://URL" lines.
      # remove-item on system entries (AirDrop, Recents) is expected to fail
      # and benign; 2>/dev/null suppresses the noise and || true keeps the
      # loop running.
      /usr/bin/sfltool list "$_sflt_list" 2>/dev/null \
        | /usr/bin/awk -F'\t' 'NF>=2{print $2}' \
        | while IFS= read -r _url; do
            if [ -n "$_url" ]; then
              /usr/bin/sfltool remove-item "$_sflt_list" "$_url" 2>/dev/null || true
            fi
          done

      # Helper: add a Finder sidebar favorite by absolute path.
      _add_finder_fav() {
        /usr/bin/sfltool add-item "$_sflt_list" "file://$1" || {
          echo "macos: failed to add Finder favorite: $1" >&2
        }
      }

      # Add canonical favorites in declared order.
      _add_finder_fav /Applications
      _add_finder_fav "$HOME/Desktop"
      _add_finder_fav "$HOME/Documents"
      _add_finder_fav "$HOME/Downloads"
      _add_finder_fav "$HOME/Music"
      _add_finder_fav "$HOME/Movies"         # "Video" maps to ~/Movies on macOS
      _add_finder_fav "$HOME/Pictures"
      _add_finder_fav "$HOME/.Trash"         # shown as "Trash Bin" in Finder
      _add_finder_fav /                      # root "/"
      _add_finder_fav "$HOME"                # user home "~/"
      _add_finder_fav "$HOME/dev"
      _add_finder_fav "$HOME/clouds"
    '';

    # -------------------------------------------------------------------------
    # refreshFinderServices
    # Restart Finder to refresh available Services in context menu after
    # installation and preference changes. This ensures "Open in Terminal",
    # "Open in iTerm", and other services are visible without a manual restart.
    # -------------------------------------------------------------------------
    refreshFinderServices = lib.hm.dag.entryAfter [ "configureFinderSidebar" "installPackages" "configureLaunchServices" ] ''
      # Restart Finder to refresh Services. This ensures services registered for
      # both file and directory contexts are loaded (e.g., "Open in Terminal").
      if ! /usr/bin/killall Finder; then
        echo "macos: Finder was not running (or could not be restarted)." >&2
      else
        echo "macos: Finder restarted; Services should now be refreshed." >&2
      fi

      # Enable Services to appear in Finder context menu for both files and
      # empty space. Set NSServicesMinimumItemCountForContextSubmenu to 0 to show
      # all services regardless of count (already set in defaults, but ensure
      # it takes effect during this activation).
      /usr/bin/defaults write NSGlobalDomain NSServicesMinimumItemCountForContextSubmenu -int 0

      # Explicitly register the Automator Quick Action workflows (Services) so
      # they are discoverable by LaunchServices and appear in Finder context menus.
      SERVICES_DIR="$HOME/Library/Services"
      if [ -d "$SERVICES_DIR" ]; then
        # Use the correct lsregister path for registering services
        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if [ -x "$LSREGISTER" ]; then
          if ! $LSREGISTER -r -domain local -domain system -domain user; then
            echo "macos: lsregister failed; Finder Services may not appear in context menus until the next login." >&2
          fi
        fi
      fi

      # Reload Finder Services to pick up the changes immediately.
      if ! /bin/launchctl kickstart -k "gui/$UID/com.apple.Finder"; then
        echo "macos: launchctl Finder restart failed; restart Finder manually if Services do not appear in context menus." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # verifyArchivingStack
    # Health check for archiving tools: verifies 7z CLI, Keka app registration,
    # and archive handler associations are functional after activation.
    # -------------------------------------------------------------------------
    verifyArchivingStack =
      lib.hm.dag.entryAfter
        [ "configureSystemHardening" "configureLaunchServices" "installPackages" "refreshFinderServices" ]
        ''
          # Verify 7z CLI is available and functional using direct Nix store path.
          # Do not rely on PATH lookup since Home Manager activation runs in a minimal
          # shell that may not have nix-darwin system package paths available yet.
          seven_z_exe="${pkgs.p7zip}/bin/7z"
          if [ ! -x "$seven_z_exe" ]; then
            echo "macos: warning — 7z binary not found at $seven_z_exe; archive extraction may fail." >&2
          elif ! "$seven_z_exe" --help >/dev/null 2>&1; then
            echo "macos: warning — 7z exists but --help failed; archive handling may be broken." >&2
          else
            echo "macos: archiving stack healthy — 7z CLI available." >&2
          fi

          # Verify Keka application is installed and registered.
          if [ ! -d "/Applications/Keka.app" ]; then
            echo "macos: warning — Keka.app not found in /Applications; GUI archiving unavailable." >&2
          else
            echo "macos: archiving stack healthy — Keka installed." >&2
          fi
        '';

    # -------------------------------------------------------------------------
    # displayHostManualInstructions
    # Prints host-scoped one-time manual setup instructions from the dedicated
    # host manual document instead of embedding long reminder strings here.
    #
    # Ordering invariant:
    #   displayHostManualInstructions must remain the terminal activation node so
    #   users always see one final, consolidated instruction block after every
    #   automated step has finished.
    # -------------------------------------------------------------------------
    displayHostManualInstructions = lib.hm.dag.entryAfter displayHostManualInstructionDeps ''
      _manual_path='${config.nucleus.hostManualFile}'
      _repo_root_file="$HOME/.config/nucleus/repo-root"
      _resolved_manual_path="$_manual_path"

      case "$_manual_path" in
        /*) ;;
        *)
          if [ -n "''${NUCLEUS_REPO:-}" ]; then
            _resolved_manual_path="$NUCLEUS_REPO/$_manual_path"
          elif [ -f "$_repo_root_file" ]; then
            _resolved_manual_path="$(cat "$_repo_root_file")/$_manual_path"
          fi
          ;;
      esac

      if [ ! -f "$_resolved_manual_path" ]; then
        echo "macos: host manual not found at $_resolved_manual_path (configured: $_manual_path)." >&2
        exit 1
      fi

      echo "--- MANUAL SETUP (one-time, required) ---" >&2
      /bin/cat "$_resolved_manual_path" >&2
      echo "-------------------------------------------" >&2
    '';

    # -------------------------------------------------------------------------
    # ensureHeadlessDisplay
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
    ensureHeadlessDisplay = lib.hm.dag.entryAfter [ "configureNightlight" ] ''
      BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
      BD_APP="/Applications/BetterDisplay.app"
      DISPLAY_NAME="HeadlessDisplay"

      create_headless_display() {
        # Use documented virtual-screen parameters and force connected state at
        # creation time so fallback remains available with the lid closed.
        "$BD_BIN" create \
          -type=VirtualScreen \
          -virtualScreenName="$DISPLAY_NAME" \
          -aspectWidth=16 \
          -aspectHeight=10 \
          -multiplierStep=160 \
          -virtualScreenHiDPI=on \
          -connected=on
      }

      discard_headless_displays() {
        # Discard by BetterDisplay tag IDs so we only touch managed virtual
        # screens and avoid affecting physical monitors.
        for tag_id in $1; do
          if ! "$BD_BIN" discard -tagID="$tag_id"; then
            echo "macos: failed to discard duplicate BetterDisplay virtual screen tagID=$tag_id." >&2
          fi
        done
      }

      if [ -f "$BD_BIN" ]; then
        if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
          /usr/bin/open -g -a "$BD_APP"
          /bin/sleep 5  # wait for the app to initialise before issuing CLI commands
        fi

        identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME")" || true
        tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        tag_count="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"

        if [ "$tag_count" -ne 1 ]; then
          if [ "$tag_count" -gt 0 ]; then
            discard_headless_displays "$tag_ids"
          fi

          if ! create_headless_display; then
            echo "macos: failed to create BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
          fi
          /bin/sleep 3  # wait for the virtual display to be registered
          identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME")" || true
          tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        else
          tag_id="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { print; exit }')"
          connected_state="$($BD_BIN get -tagID="$tag_id" -connected)" || true

          if [ "$connected_state" != "on" ]; then
            if ! "$BD_BIN" discard -tagID="$tag_id"; then
              echo "macos: failed to discard disconnected BetterDisplay virtual screen '$DISPLAY_NAME' (tagID=$tag_id)." >&2
            fi

            if ! create_headless_display; then
              echo "macos: failed to recreate BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
            fi
            /bin/sleep 3  # wait for the virtual display to be registered
            identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME")" || true
            tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
          fi
        fi

        connected_after="$($BD_BIN get -name="$DISPLAY_NAME" -connected)" || true
        if [ "$connected_after" != "on" ]; then
          echo "macos: failed to set BetterDisplay virtual screen '$DISPLAY_NAME' connected=on." >&2
        fi
      fi
    '';
  };

  # --------------------------------------------------------------------------
  # BetterDisplay heartbeat LaunchAgent
  # Polls the HeadlessDisplay virtual screen every 30 seconds and reconnects
  # it if BetterDisplay marks it as disconnected after a lid-close, sleep/wake
  # cycle, or BetterDisplay restart.
  #
  # Why a LaunchAgent rather than relying on ensureHeadlessDisplay alone:
  #   ensureHeadlessDisplay runs only during `home-manager switch`.  On a
  #   clamshell Mac that is left closed for hours, BetterDisplay can drop the
  #   virtual screen connection without a new activation run.  A launchd
  #   periodic agent is the lightest-weight persistent fix without requiring a
  #   Pro subscription or kernel extension.
  #
  # Output is silenced to prevent log spam from 30-second no-op runs.
  # --------------------------------------------------------------------------
  launchd.agents."betterdisplay-heartbeat" = {
    enable = true;
    config = {
      Label = "local.betterdisplay-heartbeat";
      ProgramArguments = [ "${betterdisplayHeartbeat}" ];
      # Poll interval in seconds; 30 s keeps the display available for
      # remote-desktop without generating excessive CPU or IPC overhead.
      StartInterval = 30;
      # Run once at load so the virtual screen is connected immediately after
      # login or a `home-manager switch` without waiting for the first tick.
      RunAtLoad = true;
      # Suppress per-invocation output to avoid filling system logs with
      # 30-second no-op heartbeat entries.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };

  # --------------------------------------------------------------------------
  # LinearMouse autostart LaunchAgent
  # Starts LinearMouse at user login so per-device scroll behavior is active
  # without manual app launch.
  # --------------------------------------------------------------------------
  launchd.agents."linearmouse-autostart" = {
    enable = true;
    config = {
      Label = "local.linearmouse-autostart";
      ProgramArguments = [
        "/usr/bin/open"
        "-gj"
        "-a"
        "/Applications/LinearMouse.app"
      ];
      RunAtLoad = true;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
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
  # on the next weekly run or load.  Check exit status with:
  #   launchctl list | grep nix-index-update
  # --------------------------------------------------------------------------
  launchd.agents."nix-index-update" = {
    enable = true;
    config = {
      Label = "local.nix-index-update";
      ProgramArguments = [ "${nixIndexUpdate}" ];
      # Run once at load so a freshly provisioned machine or a machine whose
      # DB is absent or stale gets an immediate rebuild rather than waiting
      # for the next weekly calendar window.
      RunAtLoad = true;
      # Weekly Sunday 00:00 rebuild to keep the index current with nixpkgs
      # updates.  Weekday 0 = Sunday in launchd's calendar convention.
      StartCalendarInterval = [
        {
          Hour = 0;
          Minute = 0;
          Weekday = 0;
        }
      ];
      # Suppress per-build output to avoid filling system logs.  See above.
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
