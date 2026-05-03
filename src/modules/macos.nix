# modules/macos.nix — macOS-only Home Manager activation hooks.
#
# Guards the entire module with lib.mkIf pkgs.stdenv.isDarwin so it is a no-op
# on Linux hosts even though home.nix imports it unconditionally.
#
# Activation order (Home Manager DAG):
#   writeBoundary / linkGeneration
#     → clearDesktop, configureInputAndSiri, configureITerm2Settings,
#       configureSystemHardening
#     → configureLaunchServices, configureNightlight
#       → ensureHeadlessDisplay
#         → configureDisplayResolutions
#           → displayManualInstructions
{ lib, pkgs, ... }:
let
  # UTI list for Chrome: set as the default handler for HTML and XHTML documents.
  chromeUTIs = [ "public.html" "public.xhtml" ];

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
in
lib.mkIf pkgs.stdenv.isDarwin {
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
      /usr/bin/killall Finder 2>/dev/null || true
      /usr/bin/killall WindowManager 2>/dev/null || true
      /usr/bin/killall SystemUIServer 2>/dev/null || true
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
          "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR" || true
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
            "$DP_BIN" "id:$ID $BEST_MODE" || true
          fi
        done
      fi
    '';

    # -------------------------------------------------------------------------
    # configureInputAndSiri
    # Writes input-method and keyboard shortcut defaults that cannot be expressed
    # in the nix-darwin system.defaults tree because they use the private
    # symbolichotkeys domain or require a running input method daemon reload.
    #
    #   hotkey 176 disabled  — disable the built-in "Move focus to next window"
    #                          shortcut that conflicts with custom window managers
    #   TISCapslockLanguageSwitch  — make Caps Lock switch input source
    #   AppleDictationAutoEnable   — enable dictation in all apps automatically
    #   FnKeyUsage = 1             — Fn key shows Character Viewer (not Emoji)
    #   activateSettings -u        — flush keyboard/input settings immediately
    #   killall TISwitcher         — restart the input-source switcher daemon
    # -------------------------------------------------------------------------
    configureInputAndSiri = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>" || true
      /usr/bin/defaults write -g TISCapslockLanguageSwitch -bool true || true
      /usr/bin/defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool true || true
      /usr/bin/defaults write com.apple.TextInput.Kybd FnKeyUsage -int 1 || true
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
      /usr/bin/killall -HUP TISwitcher 2>/dev/null || true
    '';

    # -------------------------------------------------------------------------
    # configureITerm2Settings
    # Enables the iTerm2 bootstrap daemon.  The daemon allows shell integration
    # scripts to communicate with iTerm2 even when the app is not the foreground
    # window, enabling features like automatic profile switching on SSH.
    # Written here (rather than in defaults.nix) because it must be idempotent
    # and the app must already be installed before this runs.
    # -------------------------------------------------------------------------
    configureITerm2Settings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/defaults write com.googlecode.iterm2 BootstrapDaemon -bool true || true
    '';

    # -------------------------------------------------------------------------
    # configureLaunchServices
    # Registers default application handlers for file types using duti.
    # Running this in a Home Manager activation keeps the associations in sync
    # every time `home-manager switch` is run, which is necessary because
    # application (re)installs can reset handler registrations.
    #
    #   Chrome — handles all HTML/XHTML documents
    #   VLC    — handles the complete set of audio/video UTIs defined above
    # -------------------------------------------------------------------------
    configureLaunchServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # register_handler BUNDLE_ID UTI [UTI ...]
      # Sets BUNDLE_ID as the default handler for each UTI across all roles.
      register_handler() {
        handler="$1"
        shift

        for uti in "$@"; do
          "${dutiBin}" -s "$handler" "$uti" all || true
        done
      }

      register_handler "com.google.chrome" ${builtins.concatStringsSep " " chromeUTIs}
      register_handler "org.videolan.vlc" ${builtins.concatStringsSep " " vlcUTIs}
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
        /opt/homebrew/bin/nightlight schedule start || true
        /opt/homebrew/bin/nightlight temp 50 || true
        current_hour=$(date +%H)
        if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
          /opt/homebrew/bin/nightlight on || true
        else
          /opt/homebrew/bin/nightlight off || true
        fi
      fi
    '';

    # -------------------------------------------------------------------------
    # configureSystemHardening
    # Applies security and performance hardening measures that require a running
    # user session (not available to system-level activationScripts):
    #
    #   Dock hot corners disabled (wdev-tl/tr/bl/br = 0): prevents accidental
    #   screen sleep or Mission Control triggers from corner hover.
    #
    #   .metadata_never_index files: tells Spotlight not to index known build
    #   artifact directories under ~/dev (node_modules, target, build, dist,
    #   etc.), which dramatically reduces indexing CPU/disk overhead and avoids
    #   Spotlight surfacing compiled binaries or cache files.
    #
    #   Dock restart: applies the hot-corner changes without a full logout.
    # -------------------------------------------------------------------------
    configureSystemHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Disable all four Dock hot corners (0 = no action).
      /usr/bin/defaults write com.apple.dock wdev-tl -int 0
      /usr/bin/defaults write com.apple.dock wdev-tr -int 0
      /usr/bin/defaults write com.apple.dock wdev-bl -int 0
      /usr/bin/defaults write com.apple.dock wdev-br -int 0

      DEV_ROOT="$HOME/dev"
      if [ -d "$DEV_ROOT" ]; then
        # Place a .metadata_never_index sentinel inside every well-known build
        # artifact directory found under ~/dev so Spotlight skips them.
        for dir_name in "node_modules" "target" "incremental" "build" "bin" "obj" "venv" ".venv" "__pycache__" "vendor" ".gradle" ".next" ".turbo" "dist"; do
          /usr/bin/find "$DEV_ROOT" -name "$dir_name" -type d -prune -exec touch "{}/.metadata_never_index" \; 2>/dev/null || true
        done
      else
        mkdir -p "$DEV_ROOT"
      fi

      /usr/bin/killall Dock 2>/dev/null || true
    '';

    # -------------------------------------------------------------------------
    # displayManualInstructions
    # Prints one-time manual setup reminders to stderr after display resolution
    # configuration is complete.  These steps cannot be automated because they
    # require user interaction in System Settings or a browser:
    #
    #   BetterDisplay — needs Accessibility + Screen Recording permissions
    #                   to control display layout and create virtual screens.
    #   Chrome Remote Desktop (CRD) — requires naming the Mac in the web UI
    #                   and granting Screen Recording + Accessibility to the
    #                   ChromeRemoteDesktopHost process.
    # -------------------------------------------------------------------------
    displayManualInstructions = lib.hm.dag.entryAfter [ "configureDisplayResolutions" ] ''
      echo "--- MANUAL SETUP (one-time, required) ---" >&2
      echo "BetterDisplay: Grant Accessibility + Screen Recording in System Settings > Privacy & Security." >&2
      echo "CRD: Visit https://remotedesktop.google.com/access to name Mac and set PIN." >&2
      echo "CRD: Enable Screen Recording + Accessibility for ChromeRemoteDesktopHost." >&2
      echo "-------------------------------------------" >&2
    '';

    # -------------------------------------------------------------------------
    # ensureHeadlessDisplay
    # Creates a BetterDisplay virtual screen named "HeadlessDisplay" (2560×1600)
    # and connects it.  This provides a persistent logical display for remote-
    # desktop sessions when no physical monitor is attached; without it, macOS
    # disables hardware-accelerated rendering and limits resolution to 1024×768.
    #
    # Steps:
    #   1. Launch BetterDisplay in the background if it is not already running.
    #   2. Create the virtual screen if it does not already appear in
    #      system_profiler SPDisplaysDataType output.
    #   3. Ensure the virtual screen is marked as connected.
    #
    # No-op if BetterDisplay is not installed.
    # -------------------------------------------------------------------------
    ensureHeadlessDisplay = lib.hm.dag.entryAfter [ "configureNightlight" ] ''
      BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
      BD_APP="/Applications/BetterDisplay.app"
      DISPLAY_NAME="HeadlessDisplay"

      if [ -f "$BD_BIN" ]; then
        if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
          /usr/bin/open -g -a "$BD_APP"
          /bin/sleep 5  # wait for the app to initialise before issuing CLI commands
        fi

        if ! /usr/sbin/system_profiler SPDisplaysDataType | /usr/bin/grep -q "$DISPLAY_NAME"; then
          "$BD_BIN" create -devicetype=virtualscreen -virtualscreenname="$DISPLAY_NAME" -width=2560 -height=1600 || true
          /bin/sleep 3  # wait for the virtual display to be registered
        fi

        "$BD_BIN" set -namelike="$DISPLAY_NAME" -connected=on || true
      fi
    '';
  };
}
