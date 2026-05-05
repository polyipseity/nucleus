# modules/macos.nix — macOS-only Home Manager activation hooks.
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
{ lib, pkgs, ... }:
let
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
    "com.apple.HIToolbox"
    "com.apple.LaunchServices"
    "com.apple.Photos"
    "com.apple.Safari"
    "com.apple.Siri"
    "com.apple.SoftwareUpdate"
    "com.apple.SubmitDiagInfo"
    "com.apple.TextEdit"
    "com.apple.TextInput.Kybd"
    "com.apple.TextInputMenu"
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

  # Host-scoped manual checklist rendered at the end of activation so operators
  # see one consolidated block after automation finishes.
  macbookManualFile = builtins.path {
    path = ../hosts/macbook/MANUAL.md;
    name = "macbook-MANUAL.md";
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
      echo "nucleus: store integrity check failed; skipping managed preference purge for safety." >&2
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
    "checkFilesChanged"
    "checkLinkTargets"
    "clearDesktop"
    "configureDisplayResolutions"
    "configureInputAndSiri"
    "configureLaunchServices"
    "configureNightlight"
    "configureSafariDefaults"
    "configureSystemHardening"
    "configureUniversalAccessDefaults"
    "ensureHeadlessDisplay"
    "installPackages"
    "linkGeneration"
    "gpgImport"
    "onFilesChange"
    "preflightPrivacyPermissions"
    "reloadUserPreferenceState"
    "sops-nix"
    "setupLaunchAgents"
    "wallpaperProvision"
    "vscodeDarwinExtensionBridge"
    "vscodeProfiles"
    "writeBoundary"
  ];
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [ managedPreferencesPurgeScript ];

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
          echo "nucleus: $proc was not running (or could not be restarted)." >&2
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
            echo "nucleus: failed to apply primary display mode with displayplacer." >&2
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
              echo "nucleus: failed to apply mode '$BEST_MODE' to display id $ID." >&2
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
        echo "nucleus: failed to update symbolic hotkey 176." >&2
      fi

      if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
        echo "nucleus: activateSettings -u failed; input settings may apply on next login." >&2
      fi

      if ! /usr/bin/killall -HUP TISwitcher; then
        echo "nucleus: TISwitcher was not running (or could not be signaled)." >&2
      fi
    '';

    # -------------------------------------------------------------------------
    # reloadUserPreferenceState
    # Forces macOS to flush/reload user defaults after all managed defaults
    # writes and domain-specific hooks.  This minimizes "ghost" values staying
    # in memory until logout/login after a rebuild.
    # -------------------------------------------------------------------------
    reloadUserPreferenceState = lib.hm.dag.entryAfter [
      "configureInputAndSiri"
      "configureSafariDefaults"
      "configureUniversalAccessDefaults"
    ] ''
      if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
        echo "nucleus: activateSettings -u failed; some preference updates may require relogin." >&2
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
            echo "nucleus: failed to register LaunchServices handler $handler for UTI $uti." >&2
          fi
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
        if ! /opt/homebrew/bin/nightlight schedule start; then
          echo "nucleus: failed to configure Nightlight schedule." >&2
        fi

        if ! /opt/homebrew/bin/nightlight temp 50; then
          echo "nucleus: failed to set Nightlight temperature." >&2
        fi

        current_hour=$(date +%H)
        if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
          if ! /opt/homebrew/bin/nightlight on; then
            echo "nucleus: failed to enable Nightlight." >&2
          fi
        else
          if ! /opt/homebrew/bin/nightlight off; then
            echo "nucleus: failed to disable Nightlight." >&2
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
      echo "nucleus: checking macOS privacy permissions before defaults writes..." >&2

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
          echo "nucleus: privacy preflight probe failed unexpectedly ($probe_err); continuing with best-effort defaults writes." >&2
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
            echo "nucleus: failed to set Safari key $key due to missing privacy authorization." >&2
          else
            echo "nucleus: failed to set Safari key $key ($write_err)." >&2
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
            echo "nucleus: failed to set $domain $key ($write_err)." >&2
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
    # Applies Spotlight indexing suppression for build artifact directories;
    # requires a running user session (not available to system-level scripts).
    #
    #   .metadata_never_index files: tells Spotlight not to index well-known
    #   build artifact directories under ~/dev (node_modules, target, build,
    #   dist, etc.), reducing indexing CPU/disk overhead and avoiding Spotlight
    #   surfacing compiled binaries or cache files.
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
            echo "nucleus: failed to mark one or more '$dir_name' directories as metadata_never_index." >&2
          fi
        done
      else
        mkdir -p "$DEV_ROOT"
      fi

      if ! /usr/bin/killall Dock; then
        echo "nucleus: Dock was not running (or could not be restarted)." >&2
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
      echo "--- MANUAL SETUP (one-time, required) ---" >&2
      /bin/cat '${macbookManualFile}' >&2
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
            echo "nucleus: failed to discard duplicate BetterDisplay virtual screen tagID=$tag_id." >&2
          fi
        done
      }

      if [ -f "$BD_BIN" ]; then
        if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
          /usr/bin/open -g -a "$BD_APP"
          /bin/sleep 5  # wait for the app to initialise before issuing CLI commands
        fi

        identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME" 2>/dev/null || true)"
        tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        tag_count="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"

        if [ "$tag_count" -ne 1 ]; then
          if [ "$tag_count" -gt 0 ]; then
            discard_headless_displays "$tag_ids"
          fi

          if ! create_headless_display; then
            echo "nucleus: failed to create BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
          fi
          /bin/sleep 3  # wait for the virtual display to be registered
          identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME" 2>/dev/null || true)"
          tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
        else
          tag_id="$(printf '%s\n' "$tag_ids" | /usr/bin/awk 'NF { print; exit }')"
          connected_state="$($BD_BIN get -tagID="$tag_id" -connected 2>/dev/null || true)"

          if [ "$connected_state" != "on" ]; then
            if ! "$BD_BIN" discard -tagID="$tag_id"; then
              echo "nucleus: failed to discard disconnected BetterDisplay virtual screen '$DISPLAY_NAME' (tagID=$tag_id)." >&2
            fi

            if ! create_headless_display; then
              echo "nucleus: failed to recreate BetterDisplay virtual screen '$DISPLAY_NAME'." >&2
            fi
            /bin/sleep 3  # wait for the virtual display to be registered
            identifiers_json="$($BD_BIN get -identifiers -name="$DISPLAY_NAME" 2>/dev/null || true)"
            tag_ids="$(printf '%s\n' "$identifiers_json" | /usr/bin/awk -F'"' '/"tagID"/ { print $4 }' | /usr/bin/sort -u)"
          fi
        fi

        connected_after="$($BD_BIN get -name="$DISPLAY_NAME" -connected 2>/dev/null || true)"
        if [ "$connected_after" != "on" ]; then
          echo "nucleus: failed to set BetterDisplay virtual screen '$DISPLAY_NAME' connected=on." >&2
        fi
      fi
    '';
  };
}
