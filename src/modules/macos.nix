{ lib, pkgs, ... }:
let
  chromeUTIs = [ "public.html" "public.xhtml" ];

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
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.activation = {
    clearDesktop = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/killall Finder 2>/dev/null || true
      /usr/bin/killall WindowManager 2>/dev/null || true
      /usr/bin/killall SystemUIServer 2>/dev/null || true
    '';

    configureDisplayResolutions = lib.hm.dag.entryAfter [ "ensureHeadlessDisplay" ] ''
      DP_BIN="/opt/homebrew/bin/displayplacer"

      if [ -x "$DP_BIN" ]; then
        FULL_LIST=$("$DP_BIN" list)

        PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/awk '
          /^Persistent screen id:/ { last_id=$4 }
          /Type: MacBook built in screen/ { print last_id; exit }
        ')

        if [ -z "$PRIMARY_ID" ]; then
          PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/head -n 1 | /usr/bin/awk '{print $4}')
        fi

        MODE4_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /^  mode 4:/ {
            sub(/^[ ]*mode 4: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

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

        if [ -n "$MODE4_STR" ]; then
          "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR" || true
          /bin/sleep 1
          FULL_LIST=$("$DP_BIN" list)
        fi

        TARGET_STR=$(echo "$FULL_LIST" | /usr/bin/awk -v id="$PRIMARY_ID" '
          $0 ~ id { found=1 }
          found && /<-- current mode/ {
            sub(/^[ ]*mode [0-9]+: /, "");
            sub(/[ ]*<-- current mode/, "");
            print $0;
            exit;
          }
        ')

        T_W=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:([0-9]+)x.*/\1/')
        T_H=$(echo "$TARGET_STR" | /usr/bin/sed -E 's/.*res:[0-9]+x([0-9]+).*/\1/')
        T_SCALING=""
        if echo "$TARGET_STR" | /usr/bin/grep -q "scaling:on"; then
          T_SCALING="scaling:on"
        fi

        for ID in $(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/awk '{print $4}'); do
          if [ "$ID" = "$PRIMARY_ID" ]; then
            continue
          fi

          MODES=$(echo "$FULL_LIST" | /usr/bin/sed -n "/^Persistent screen id: $ID/,/^Persistent screen id:/p" | /usr/bin/grep "^  mode " | /usr/bin/sed 's/^  mode [0-9]*: //')
          if [ -n "$T_SCALING" ]; then
            MODES=$(echo "$MODES" | /usr/bin/grep "scaling:on")
          fi

          BEST_MODE=$(echo "$MODES" | /usr/bin/awk -v tw="$T_W" -v th="$T_H" '{ w=substr($0,index($0,"res:")+4); gsub(/[^0-9].*/,"",w); h=substr($0,index($0,"x")+1); gsub(/[^0-9].*/,"",h); if (w+0>=tw+0 && h+0<=th+0 && h+0>0) print w+0, h+0, $0 }' | /usr/bin/sort -n | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f3- | /usr/bin/sed 's/ <-- current mode$//')

          if [ -n "$BEST_MODE" ]; then
            "$DP_BIN" "id:$ID $BEST_MODE" || true
          fi
        done
      fi
    '';

    configureInputAndSiri = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>" || true
      /usr/bin/defaults write -g TISCapslockLanguageSwitch -bool true || true
      /usr/bin/defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool true || true
      /usr/bin/defaults write com.apple.TextInput.Kybd FnKeyUsage -int 1 || true
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
      /usr/bin/killall -HUP TISwitcher 2>/dev/null || true
    '';

    configureITerm2Settings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/defaults write com.googlecode.iterm2 BootstrapDaemon -bool true || true
    '';

    configureLaunchServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
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

    configureSystemHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      /usr/bin/defaults write com.apple.dock wdev-tl -int 0
      /usr/bin/defaults write com.apple.dock wdev-tr -int 0
      /usr/bin/defaults write com.apple.dock wdev-bl -int 0
      /usr/bin/defaults write com.apple.dock wdev-br -int 0

      DEV_ROOT="$HOME/dev"
      if [ -d "$DEV_ROOT" ]; then
        for dir_name in "node_modules" "target" "incremental" "build" "bin" "obj" "venv" ".venv" "__pycache__" "vendor" ".gradle" ".next" ".turbo" "dist"; do
          /usr/bin/find "$DEV_ROOT" -name "$dir_name" -type d -prune -exec touch "{}/.metadata_never_index" \; 2>/dev/null || true
        done
      else
        mkdir -p "$DEV_ROOT"
      fi

      /usr/bin/killall Dock 2>/dev/null || true
    '';

    displayManualInstructions = lib.hm.dag.entryAfter [ "configureDisplayResolutions" ] ''
      echo "--- MANUAL SETUP (one-time, required) ---" >&2
      echo "BetterDisplay: Grant Accessibility + Screen Recording in System Settings > Privacy & Security." >&2
      echo "CRD: Visit https://remotedesktop.google.com/access to name Mac and set PIN." >&2
      echo "CRD: Enable Screen Recording + Accessibility for ChromeRemoteDesktopHost." >&2
      echo "-------------------------------------------" >&2
    '';

    ensureHeadlessDisplay = lib.hm.dag.entryAfter [ "configureNightlight" ] ''
      BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
      BD_APP="/Applications/BetterDisplay.app"
      DISPLAY_NAME="HeadlessDisplay"

      if [ -f "$BD_BIN" ]; then
        if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
          /usr/bin/open -g -a "$BD_APP"
          /bin/sleep 5
        fi

        if ! /usr/sbin/system_profiler SPDisplaysDataType | /usr/bin/grep -q "$DISPLAY_NAME"; then
          "$BD_BIN" create -devicetype=virtualscreen -virtualscreenname="$DISPLAY_NAME" -width=2560 -height=1600 || true
          /bin/sleep 3
        fi

        "$BD_BIN" set -namelike="$DISPLAY_NAME" -connected=on || true
      fi
    '';
  };
}
