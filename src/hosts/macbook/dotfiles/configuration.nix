{ currentUserName, hostName, pkgs, userList, ... }:
let
  # Enable or disable Arduino IDE 1.8.19 installation.
  enableArduinoIDE = true;

  # Reuse this literal in both enabled and selected input source lists.
  usKeyboard = {
    InputSourceKind = "Keyboard Layout";
    "Keyboard Layout ID" = 0;
    "Keyboard Layout Name" = "U.S.";
  };

  cangjieInputMethod = {
    "Bundle ID" = "com.apple.inputmethod.TCIM";
    InputSourceKind = "Input Method";
    "Input Method Identifier" = "com.apple.inputmethod.TCIM.Cangjie";
  };

  # Ordered input methods. First item is the default on startup.
  inputMethods = [
    usKeyboard
    cangjieInputMethod
  ];

  # Keep GUI app selection in one place so updates are easy to review.
  managedCasks = [
    "appcleaner"
    "alt-tab"
    "betterdisplay"
    "chrome-remote-desktop-host"
    "coolterm"
    "discord@canary"
    "google-chrome"
    "google-chrome@canary"
    "iterm2"
    "lulu"
    "obsidian"
    "orbstack"
    "parsec" # Includes required virtual display/input drivers.
    "raycast"
    "rectangle"
    "stats"
    "telegram-desktop@beta"
    "utm"
    "visual-studio-code"
    "visual-studio-code@insiders"
    "vlc"
    "whatsapp@beta"
  ];

  # Keep CLI package selection centralized in let-bound data.
managedSystemPackages = with pkgs; [
    # arduino: not available for aarch64-darwin (install manually: https://downloads.arduino.cc/arduino-ide/arduino-ide_1.8.19_macos_aarch64.tar.xz)
    bat
    bottom
    desktoppr
    direnv
    duti
    fzf
    git
    gnupg
    opencode
    (pass.withExtensions (exts: [ exts.pass-otp ]))
    pinentry_mac
    ripgrep
    uv
    rustup  # Rust toolchain bootstrap. Day-to-day compilers should come from project shells.
    zoxide
  ];

  # Homebrew brews managed by nix-darwin.
  managedBrews = [
    "displayplacer"
    "smudge/smudge/nightlight"
    "zackelia/formulae/bclm"
  ];

  # Auto-derive tap names from brews/casks that contain a slash (e.g. "smudge/smudge/nightlight" -> "smudge/smudge").
  # Must use builtins only at this scope (lib is not in scope at the top-level let).
  extractTap = item:
    let matches = builtins.match "(.*)/[^/]+" item;
    in if matches == null then null else builtins.elemAt matches 0;
  defaultTaps = [ "homebrew/core" "homebrew/cask" ];
  allTaps = let
    rawTaps = builtins.filter (x: x != null) (map extractTap (managedBrews ++ managedCasks));
    # Remove default taps (homebrew/core, homebrew/cask) which are auto-managed.
    filtered = builtins.filter (tap: !(builtins.elem tap defaultTaps)) rawTaps;
  in builtins.foldl' (acc: tap: if builtins.elem tap acc then acc else acc ++ [ tap]) [ ] filtered;

  # Source gallery tracked in this repository.
  wallpaperGallerySource = ./files/wallpapers;

  mkManagedUser =
    name:
    { config, lib, ... }:
    let
      # iCloud path is user-specific and includes spaces, so we build it once.
      iCloudRoot = "/Users/${name}/Library/Mobile Documents/com~apple~CloudDocs";
      secretsDir = "${iCloudRoot}/dotfiles/files/secrets";
      isPrimaryUser = name == currentUserName;
      gpgBin = lib.getExe pkgs.gnupg;
      desktopprBin = lib.getExe pkgs.desktoppr;

      # Build duti lines for registration (register_handler handles errors).
      duti = "${pkgs.duti}/bin/duti";
      dutiLine = app: uti: "${duti} -s \"${app}\" ${uti} all";
      chromeUTIs = [ "public.html" "public.xhtml" ];
      vlcUTIs = [
        "public.movie" "public.video" "public.audio" "public.audiovisual-content"
        "public.mp3" "public.mpeg" "public.mpeg-4" "public.mpeg-2-video"
        "public.mpeg-2-transport-stream"
        "com.apple.quicktime-movie" "com.apple.m4a-audio" "com.apple.m4v-video"
        "public.avi" "public.3gpp" "public.3gpp2"
        "org.xiph.flac" "org.matroska.mka" "org.matroska.mkv"
        "org.videolan.webm" "org.xiph.ogg-audio"
        "org.xiph.ogg-video" "org.xiph.opus"
        "com.microsoft.advanced-systems-format"
        "com.real.realaudio" "com.real.realmedia"
        "public.dv-movie" "org.smpte.mxf" "public.flc-animation"
        "public.aiff-audio" "com.microsoft.waveform-audio"
        "public.aifc-audio" "com.apple.coreaudio-format"
        "public.m3u-playlist" "public.pls-playlist"
      ];
      dutiScript = lib.concatMapStringsSep "\n" (dutiLine "com.google.chrome") chromeUTIs
        + "\n" + lib.concatMapStringsSep "\n" (dutiLine "org.videolan.vlc") vlcUTIs;
    in
    {
      # Bump only when intentionally adopting breaking Home Manager changes.
      home.stateVersion = "24.11";

      # Declarative iCloud symlink - managed by Home Manager lifecycle.
      home.file = {
        "iCloud" = {
          source = config.lib.file.mkOutOfStoreSymlink iCloudRoot;
        };
      } // lib.optionalAttrs isPrimaryUser {
        # Declarative SSH key symlinks (only for primary user).
        ".ssh/id_ed25519" = {
          source = config.lib.file.mkOutOfStoreSymlink "${secretsDir}/id_ed25519";
        };
        ".ssh/id_ed25519.pub" = {
          source = config.lib.file.mkOutOfStoreSymlink "${secretsDir}/id_ed25519.pub";
        };
        ".ssh/id_rsa" = {
          source = config.lib.file.mkOutOfStoreSymlink "${secretsDir}/id_rsa";
        };
        ".ssh/id_rsa.pub" = {
          source = config.lib.file.mkOutOfStoreSymlink "${secretsDir}/id_rsa.pub";
        };
      };

      # =============================================================================
# IMPORTANT STRUCTURE RULES:
# - targets.darwin.defaults: ONLY contains plist key-value pairs (NSGlobalDomain, com.apple.finder, etc.)
# - home.activation: Contains executable scripts (lib.hm.dag.entryAfter, echo, killall, defaults write)
# - NEVER put home.activation inside targets.darwin.defaults - scripts will NOT execute!
# =============================================================================

      # These defaults are scoped per user, not globally.
      targets.darwin.defaults = {
        NSGlobalDomain = {
          AppleInterfaceStyleSwitchesAutomatically = true;

          # Keyboard repeat tuning.
          InitialKeyRepeat = 15;
          KeyRepeat = 2;

          # Disable Press-and-Hold for key repeat (essential for Vim).
          ApplePressAndHoldEnabled = false;

          # Use F1/F2/... as standard function keys unless Fn is held.
          "com.apple.keyboard.fnState" = true;

          # Expand save/print dialogs by default.
          NSNavPanelExpandedStateForSaveMode = true;
          NSNavPanelExpandedStateForSaveMode2 = true;
          PMPrintingExpandedStateForPrint = true;
          PMPrintingExpandedStateForPrint2 = true;

          # Force 24-hour time in menu bar and apps that respect ICU settings.
          AppleICUForce24HourTime = true;

          # Disable font smoothing (crisp text on Retina displays).
          AppleFontSmoothing = 0;

          # Enable full keyboard navigation (Tab moves between all controls).
          AppleKeyboardUIMode = 2;

          # Enable trackpad tap-to-click.
          "com.apple.mouse.tapBehavior" = 1;

          # Show scroll bars always.
          AppleShowScrollBars = "Always";

          # Click scroll bar to jump to next page instead of scrolling one line.
          AppleScrollerPagingBehavior = true;

          # Natural scrolling (swipe direction).
          "com.apple.swipescrolldirection" = true;

          # Large sidebar icon size.
          NSTableViewDefaultSizeMode = 3;

          # Disable window animations.
          NSAutomaticWindowAnimationsEnabled = false;

          # Fastest trackpad tracking speed.
          "com.apple.trackpad.scaling" = 3.0;

          # Instant window animations (reduce spring delay).
          "com.apple.springing.delay" = 0.0;

          # Disable smart typing substitutions.
          NSAutomaticQuoteSubstitutionEnabled = false;
          NSAutomaticDashSubstitutionEnabled = false;
          NSAutomaticSpellingCorrectionEnabled = false;
          NSAutomaticCapitalizationEnabled = false;

          # Toolbar title rollover delay (show proxy icon immediately).
          NSToolbarTitleViewRolloverDelay = 0.0;

          # Large context menu: show all items inline, no submenu.
          NSServicesMinimumItemCountForContextSubmenu = 9999;

          # Text replacements (available system-wide).
          NSUserDictionaryReplacementItems = [
            { replace = "contravariance"; "with" = "contravariance"; }
            { replace = "contravariant"; "with" = "contravariant"; }
            { replace = "covariance"; "with" = "covariance"; }
            { replace = "covector"; "with" = "covector"; }
            { replace = "covectors"; "with" = "covectors"; }
            { replace = "flashcard"; "with" = "flashcard"; }
            { replace = "flashcards"; "with" = "flashcards"; }
            { replace = "Google"; "with" = "Google"; }
            { replace = "IME"; "with" = "IME"; }
            { replace = "Microsoft"; "with" = "Microsoft"; }
            { replace = "omw"; "with" = "在路上了！"; }
            { replace = "OneDrive"; "with" = "OneDrive"; }
            { replace = "pullback"; "with" = "pullback"; }
            { replace = "pushforward"; "with" = "pushforward"; }
            { replace = "SynthID"; "with" = "SynthID"; }
          ];
        };

        "com.apple.universalaccess" = {
          # Show window title icons (proxy icons) always visible.
          showWindowTitlebarIcons = true;
          # Accessibility font size: AX1 = 20pt.
          FontSizeCategory = "AX1";
          # Cursor size 33% larger than default (1.0 = default, 2.0 = max).
          cursorSize = 1.33;
          # Explicitly disable reduce motion and transparency.
          reduceMotion = false;
          reduceTransparency = false;
        };

        "com.apple.BezelServices" = {
          # Auto adjust keyboard brightness.
          dAuto = true;
          # Turn keyboard backlight off after inactivity.
          kDim = true;
          kDimTime = 5;
        };

        "com.betterdisplay" = {
          # Show all monitor resolutions and use the largest one.
          ShowResolutionsAsList = true;
          UseMaximumResolution = true;
          # Keep BetterDisplay running (needed for virtual screen and CLI).
          LaunchAtLogin = true;
        };

        "com.apple.AppleMultitouchTrackpad" = {
          # Silent/haptic clicking at lowest strength.
          ActuationStrength = 0;
          # Light pressure for first click.
          FirstClickThreshold = 0;
          # Enable three-finger drag.
          TrackpadThreeFingerDrag = true;
          # Enable Force Click.
          ForceSuppressed = false;
        };

        "com.apple.spaces" = {
          # Each display has its own separate spaces.
          "spans-displays" = false;
        };

        "com.apple.Safari" = {
          # Disable Safari autofill passwords (privacy reinforcement).
          AutoFillPasswords = false;
        };

        "com.apple.HIToolbox" = {
          AppleEnabledInputSources = inputMethods;
          AppleSelectedInputSources = [ (builtins.head inputMethods) ];
        };

        "com.apple.LaunchServices" = {
          # Security trade-off: turning quarantine off removes first-open warnings.
          # Keep this only if you are comfortable auditing downloads manually.
          LSQuarantine = false;
        };

        "com.apple.assistant.support" = {
          # Enable Dictation.
          "Dictation Enabled" = true;
          # Enable Auto Punctuation.
          "Auto Punctuation Enabled" = true;
          # Enable Siri & Dictation Audio Sharing (Opt-in).
          "Siri Data Sharing Opt-In Status" = 1;
          # Enable Assistant.
          "Assistant Enabled" = true;
        };

        "com.apple.speech.recognition.AppleSpeechRecognition.prefs" = {
          # Dictation shortcut: 2 = Double-press Fn
          DictationShortcut = 2;
        };



        "com.apple.TextInputMenu".visible = true;

        "com.apple.menuextra.clock" = {
          DateFormat = "EEE y-MM-dd HH:mm:ss";
          ShowDate = 1;
          ShowDayOfWeek = true;
          ShowSeconds = true;
        };

        "com.apple.controlcenter" = {
          BatteryShowPercentage = true;
          NSStatusItemSelectionPadding = 6;
          NSStatusItemSpacing = 6;
        };

        "com.apple.Siri" = {
          StatusMenuVisible = false;
          # Type to Siri (access Siri via keyboard).
          TypeToSiriEnabled = true;
          # KeyboardShortcut: 1 = Fn double-press
          KeyboardShortcut = 1;
        };

        "com.googlecode.iterm2" = {
          # Allow terminal apps to access the system clipboard (enables OSC 52).
          "AllowClipboardAccess" = true;
          # Check for updates at startup.
          "SUEnableAutomaticChecks" = true;
          "SUCheckAtStartup" = true;
          # Beta/testing channel.
          "SUFeedURL" = "https://iterm2.com/appcasts/testing_modern.xml";
          # Enable Tip of the Day.
          "NoSyncTipOfTheDay" = false;
          # Enable Secure Keyboard Entry.
          "Secure Input" = true;
          # Enable shell integration daemon.
          "BootstrapDaemon" = true;
        };

        "com.apple.terminal" = {
          # Focus follows mouse (window gets focus on hover).
          FocusFollowsMouse = "YES";
        };

        "com.apple.finder" = {
          # QuickLook text selection.
          QLEnableTextSelection = true;
        };

        "com.apple.desktopservices" = {
          # Avoid .DS_Store files on removable/network volumes.
          DSDontWriteNetworkStores = true;
          DSDontWriteUSBStores = true;
        };

        "com.apple.dock" = {
          orientation = "bottom";
          mineffect = "scale";
          launchanim = true;
          autohide = true;

          # Keep Space order stable.
          mru-spaces = false;

          minimize-to-application = true;
          show-recents = false;

          # Only show active apps in Dock.
          static-only = true;

          # Group windows by app in Mission Control.
          "expose-group-by-app" = true;

          # Largest dock icon size (max 128).
          tilesize = 128;
          largesize = 128;

          # Enable dock magnification.
          magnification = true;
        };

        "com.apple.finder" = {
          _FXShowPosixPathInTitle = true;
          AppleShowAllExtensions = true;
          FXPreferredViewStyle = "clmv";

          # Enable 30-day trash auto-cleanup.
          FXRemoveOldTrashItems = true;
          ShowPathbar = true;
          ShowStatusBar = true;

          # Search current folder by default.
          FXDefaultSearchScope = "SCcf";

          # Warn before emptying trash.
          WarnOnEmptyTrash = true;

          # Disable extension change warning.
          FXEnableExtensionChangeWarning = false;

          # Show drive icons on desktop.
          CreateDesktop = true;
          ShowExternalHardDrivesOnDesktop = true;
          ShowHardDrivesOnDesktop = true;
          ShowMountedServersOnDesktop = true;
          ShowRemovableMediaOnDesktop = true;

          # iCloud Drive sync for Desktop and Documents
          FXICloudDriveDesktop = true;
          FXICloudDriveDocuments = true;
        };

        "com.apple.WindowManager" = {
          StandardHideWidgets = true;
          EnableStandardClickToShowDesktop = true;
          WindowTilingEnabled = true;
        };

        # Privacy & Ad Tracking
        "com.apple.AdLib" = {
          allowApplePersonalizedAdvertising = false;
        };

        # Activity Monitor: 1-second updates, CPU History in Dock
        "com.apple.ActivityMonitor" = {
          UpdatePeriod = 1;
          IconType = 5;
        };

        # Spotlight: Exclude clutter categories
        "com.apple.spotlight" = {
          orderedItems = [
            { enabled = true; name = "APPLICATIONS"; }
            { enabled = true; name = "SYSTEM_SETTINGS"; }
            { enabled = true; name = "DIRECTORIES"; }
            { enabled = true; name = "PDF"; }
            { enabled = true; name = "FONTS"; }
            { enabled = true; name = "DOCUMENTS"; }
            { enabled = true; name = "MESSAGES"; }
            { enabled = true; name = "CONTACTS"; }
            { enabled = true; name = "EVENT_TODO"; }
            { enabled = true; name = "IMAGES"; }
            { enabled = true; name = "BOOKMARKS"; }
            { enabled = true; name = "MUSIC"; }
            { enabled = true; name = "MOVIES"; }
            { enabled = true; name = "PRESENTATIONS"; }
            { enabled = true; name = "SPREADSHEETS"; }
            { enabled = true; name = "SOURCE"; }
            { enabled = false; name = "MENU_SUGGESTIONS"; }
            { enabled = false; name = "MENU_WEBSEARCH"; }
          ];
        };

        # Security: Screensaver password (instant lock on lid close)
        "com.apple.screensaver" = {
          askForPassword = true;
          askForPasswordDelay = 0;
        };

        # Screenshot: Desktop, no shadow, PNG
        "com.apple.screencapture" = {
          location = "~/Desktop";
          disable-shadow = true;
          type = "png";
        };

        # Universal Control
        "com.apple.universalcontrol" = {
          autoConnect = true;
        };

        # TextEdit: Plain text mode
        "com.apple.TextEdit" = {
          RichText = false;
        };

        # Safari: Developer menus
        "com.apple.Safari" = {
          IncludeDevelopMenu = true;
          IncludeInternalDebugMenu = true;
        };

        # iCloud sidebar visibility
        "com.apple.sidebarlists" = {
          showicloud = true;
        };

        # Photos cloud sync
        "com.apple.Photos" = {
          CloudPhotosEnabled = 1;
          ImportToCloudEnabled = 1;
        };
      };

      # =============================================================================
      # home.activation: Executable scripts that run during Home Manager activation.
      # NOTE: displayManualInstructions should ALWAYS be the last script so user sees it.
      # =============================================================================
      home.activation = {
        clearDesktop = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          echo "Refreshing desktop and menu bar..." >&2
          /usr/bin/killall Finder || echo "  [INFO] Finder was not running; skip refresh." >&2
          /usr/bin/killall WindowManager || echo "  [INFO] WindowManager was not running; skip refresh." >&2
          /usr/bin/killall SystemUIServer || echo "  [INFO] SystemUIServer was not running; skip refresh." >&2
        '';

        configureInputAndSiri = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          echo "Configuring input sources and keyboard shortcuts..." >&2
          /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 176 "<dict><key>enabled</key><false/></dict>" || echo "  [INFO] Symbolichotkeys config may have failed; continuing." >&2
          /usr/bin/defaults write -g TISCapslockLanguageSwitch -bool true || echo "  [INFO] TISCapslockLanguageSwitch may have failed; continuing." >&2
          /usr/bin/defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool true || echo "  [INFO] DictationAutoEnable may have failed; continuing." >&2
          /usr/bin/defaults write com.apple.TextInput.Kybd FnKeyUsage -int 1 || echo "  [INFO] FnKeyUsage may have failed; continuing." >&2
          /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || echo "  [INFO] activateSettings not available; continuing." >&2
          /usr/bin/killall -HUP TISwitcher 2>/dev/null || echo "  [INFO] TISwitcher not running; skip refresh." >&2
        '';

        configureITerm2Updates = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          echo "Configuring iTerm2 Touch ID sudo prompt..." >&2
          /usr/bin/defaults write com.googlecode.iterm2 "BootstrapDaemon" -bool true || echo "  [INFO] BootstrapDaemon may have failed; continuing." >&2
        '';

        configureLaunchServices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          echo "Configuring com.apple.launchservices.secure via duti..." >&2
          register_handler() {
            local handler=$1; shift
            for uti in "$@"; do
              if ! "${pkgs.duti}/bin/duti" -s "$handler" "$uti" all; then
                echo "  [INFO] UTI '$uti' not registered (likely not supported on this macOS version)." >&2
              fi
            done
          }
          register_handler "com.google.chrome" ${builtins.concatStringsSep " " chromeUTIs}
          register_handler "org.videolan.vlc" ${builtins.concatStringsSep " " vlcUTIs}
        '';

        configureSystemHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          echo "Executing imperative system configurations..." >&2

          # Hot Corners: Set all to None
          /usr/bin/defaults write com.apple.dock wdev-tl -int 0
          /usr/bin/defaults write com.apple.dock wdev-tr -int 0
          /usr/bin/defaults write com.apple.dock wdev-bl -int 0
          /usr/bin/defaults write com.apple.dock wdev-br -int 0



          # Software Updates
          /usr/bin/defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
          /usr/bin/defaults write com.apple.SoftwareUpdate AutomaticDownload -bool true
          /usr/bin/defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
          /usr/bin/defaults write com.apple.commerce AutoUpdate -bool true

          # Spotlight: Exclude high-churn dev directories.
          echo "Hardening Spotlight exclusions for minimalist workspace (~/dev)..." >&2

          DEV_ROOT="$HOME/dev"
          if [ -d "$DEV_ROOT" ]; then
            echo "  Index-gating high-churn and Rust incremental directories in $DEV_ROOT..." >&2
            for dir_name in "node_modules" "target" "incremental" "build" "bin" "obj" "venv" ".venv" "__pycache__" "vendor" ".gradle" ".next" ".turbo" "dist"; do
              /usr/bin/find "$DEV_ROOT" -name "$dir_name" -type d -prune -exec touch "{}/.metadata_never_index" \; 2>/dev/null || true
            done
          else
            echo "  Creating $DEV_ROOT for development work..." >&2
            mkdir -p "$DEV_ROOT"
          fi

          /usr/bin/killall Dock 2>/dev/null || echo "  [INFO] Dock not running; skip refresh." >&2
        '';

# Advanced UI settings are now declarative in targets.darwin.defaults.
        # Keyboard backlight timeout moved to system.activationScripts.

        configureNightlight = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          # nightlight is in Homebrew tap smudge/smudge/nightlight
          if [ -x "/opt/homebrew/bin/nightlight" ]; then
            /opt/homebrew/bin/nightlight schedule start
            /opt/homebrew/bin/nightlight temp 50
            current_hour=$(date +%H)
            if [ "$current_hour" -ge 18 ] || [ "$current_hour" -lt 6 ]; then
              /opt/homebrew/bin/nightlight on
            else
              /opt/homebrew/bin/nightlight off
            fi
          else
            echo "WARNING: nightlight not found at /opt/homebrew/bin/nightlight" >&2
          fi
        '';

        # Point each user session to the managed wallpaper gallery.
        # Resolve the Nix store symlink so macOS wallpaper manager can see the physical path.
        configureWallpaperShuffle = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          wallpaper_dir=$(readlink -f "${wallpaperGallerySource}")
          desktoppr_bin="${desktopprBin}"

          if [ -d "$wallpaper_dir" ] && [ -x "$desktoppr_bin" ]; then
            echo "Assigning resolved wallpaper directory: $wallpaper_dir" >&2
            if ! "$desktoppr_bin" "$wallpaper_dir" >/dev/null 2>&1; then
              echo "WARNING: desktoppr failed to set the wallpaper directory." >&2
            fi
          else
            echo "WARNING: Wallpaper directory source could not be resolved." >&2
          fi
        '';

        # BETTERDISPLAY FREE TIER CONSTRAINTS:
        # - Use only system_profiler (not BetterDisplay APIs) to detect HeadlessDisplay.
        # - Do NOT use Dummy/Sidecar displays; use virtualscreen only.
        # - Do NOT use custom/DDC control; use independent tools (nightlight, bclm).
        # - Only ONE virtual display allowed in free tier.
        # - displayplacer picks system-native modes only (no custom HiDPI injection).
        # - Resolution matching: smallest width >= primary, highest height <= primary.
        # - Always strip "<-- current mode" from mode strings before passing to displayplacer.
        # - Use MODE4_STR (strip <-- current mode) for primary, TARGET_STR (strip <-- current mode) for others.
        # - displayplacer mode lines have TWO spaces prefix ("^  mode ").
        # - macOS awk: match() with array capture is broken; use substr/index/gsub instead.
        # - macOS awk: always use +0 suffix for numeric comparisons to avoid string comparison.
        ensureHeadlessDisplay = lib.hm.dag.entryAfter [ "configureWallpaperShuffle" ] ''
          BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
          BD_APP="/Applications/BetterDisplay.app"
          DISPLAY_NAME="HeadlessDisplay"

          if [ -f "$BD_BIN" ]; then
            echo "Hardening Virtual Display '$DISPLAY_NAME' via System Profiler..." >&2

            if ! /usr/bin/pgrep -x "BetterDisplay" > /dev/null; then
              echo "Starting BetterDisplay background process..." >&2
              /usr/bin/open -g -a "$BD_APP"
              /bin/sleep 5
            fi

            if ! /usr/sbin/system_profiler SPDisplaysDataType | /usr/bin/grep -q "$DISPLAY_NAME"; then
              echo "Display '$DISPLAY_NAME' not detected by macOS. Creating..." >&2
              "$BD_BIN" create -devicetype=virtualscreen -virtualscreenname="$DISPLAY_NAME" -width=2560 -height=1600 || echo "  [INFO] Virtual display creation may have failed; continuing." >&2
              /bin/sleep 3
            else
              echo "Virtual display '$DISPLAY_NAME' already detected by system. Skipping creation." >&2
            fi

            "$BD_BIN" set -namelike="$DISPLAY_NAME" -connected=on || echo "  [INFO] BetterDisplay set connected may have failed; continuing." >&2
          fi
        '';

        configureDisplayResolutions = lib.hm.dag.entryAfter [ "ensureHeadlessDisplay" ] ''
          DP_BIN="/opt/homebrew/bin/displayplacer"

          if [ -x "$DP_BIN" ]; then
            echo "Setting all displays to matching HiDPI resolutions..." >&2

            FULL_LIST=$("$DP_BIN" list)

            PRIMARY_ID=$(echo "$FULL_LIST" | /usr/bin/awk '
              /^Persistent screen id:/ { last_id=$4 }
              /Type: MacBook built in screen/ { print last_id; exit }
            ')

            if [ -z "$PRIMARY_ID" ]; then
              echo "Warning: Could not identify built-in screen. Falling back to first screen." >&2
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
              "$DP_BIN" "id:$PRIMARY_ID $MODE4_STR" || echo "  [INFO] displayplacer primary mode may have failed; continuing." >&2
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
            if [ -n "$T_SCALING" ]; then echo "Target: $T_W x $T_H $T_SCALING" >&2; else echo "Target: $T_W x $T_H" >&2; fi

            for ID in $(echo "$FULL_LIST" | /usr/bin/grep "Persistent screen id:" | /usr/bin/awk '{print $4}'); do
              if [ "$ID" = "$PRIMARY_ID" ]; then
                continue
              fi
              if [ -n "$T_SCALING" ]; then echo "Matching screen $ID to $T_W x $T_H (scaling)..." >&2; else echo "Matching screen $ID to $T_W x $T_H..." >&2; fi
              MODES=$(echo "$FULL_LIST" | /usr/bin/sed -n "/^Persistent screen id: $ID/,/^Persistent screen id:/p" | /usr/bin/grep "^  mode " | /usr/bin/sed 's/^  mode [0-9]*: //')
              if [ -n "$T_SCALING" ]; then
                MODES=$(echo "$MODES" | /usr/bin/grep "scaling:on")
              fi
              BEST_MODE=$(echo "$MODES" | /usr/bin/awk -v tw="$T_W" -v th="$T_H" '{ w=substr($0,index($0,"res:")+4); gsub(/[^0-9].*/,"",w); h=substr($0,index($0,"x")+1); gsub(/[^0-9].*/,"",h); if (w+0>=tw+0 && h+0<=th+0 && h+0>0) print w+0, h+0, $0 }' | /usr/bin/sort -n | /usr/bin/head -n 1 | /usr/bin/cut -d' ' -f3- | /usr/bin/sed 's/ <-- current mode$//')
              if [ -n "$BEST_MODE" ]; then
                echo "Best-fit: $BEST_MODE" >&2
                "$DP_BIN" "id:$ID $BEST_MODE" || echo "  [INFO] displayplacer secondary mode may have failed for $ID; continuing." >&2
              else
                echo "No matching mode for $ID. Skipping." >&2
              fi
            done
          fi
        '';

        # NOTE: displayManualInstructions should ALWAYS be the last activation script.
        # This ensures the user sees the manual setup steps after all automated configuration completes.
        displayManualInstructions = lib.hm.dag.entryAfter [ "configureDisplayResolutions" ] ''
          echo "--- MANUAL SETUP (one-time, required) ---" >&2
          echo "BetterDisplay: Grant Accessibility + Screen Recording in System Settings > Privacy & Security." >&2
          echo "CRD: Visit https://remotedesktop.google.com/access to name Mac and set PIN." >&2
          echo "CRD: Enable Screen Recording + Accessibility for ChromeRemoteDesktopHost." >&2
          echo "-------------------------------------------" >&2
          echo "Applying lid-closed server-mode (disablesleep, lidwake, displaysleep=0)..." >&2
          echo "Enabling system diagnostic reporting..." >&2
        '';
      } // lib.optionalAttrs isPrimaryUser {
        # Import the armored key and apply ultimate trust when present.
        importGpg = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          echo "Verifying and trusting GPG private key for ${name}..." >&2

          GPG_KEY_FILE="${secretsDir}/gnupg.asc"

          if [ -f "$GPG_KEY_FILE" ]; then
            if ! "${gpgBin}" --batch --import "$GPG_KEY_FILE"; then
              echo "[ERROR] GPG private key import failed for $GPG_KEY_FILE" >&2
            else
              echo "  [INFO] GPG private key imported successfully." >&2

              FPR=$("${gpgBin}" --with-colons --import-options show-only --import "$GPG_KEY_FILE" | /usr/bin/awk -F: '$1=="fpr"{print $10;exit}')

              if [ -n "$FPR" ]; then
                echo "Applying ultimate trust to fingerprint: $FPR" >&2
                echo "$FPR:6:" | "${gpgBin}" --import-ownertrust
              else
                echo "  [INFO] Could not resolve fingerprint for trust assignment." >&2
              fi
            fi
          else
            echo "  [INFO] GPG private key not found at $GPG_KEY_FILE; skipping." >&2
          fi
        '';
      };
    };
in
{
  assertions = [
    {
      assertion = userList != [ ];
      message = "userList must contain at least one managed user.";
    }
    {
      assertion = builtins.elem currentUserName userList;
      message = "currentUserName must be included in userList.";
    }
  ];

  # Determinate Nix manages its own daemon; nix-darwin's daemon must remain off.
  nix.enable = false;
  nix.settings.experimental-features = "nix-command flakes";
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 5;

  # Keep host names consistent across Finder, terminal prompts, and local network services.
  networking.hostName = hostName;
  networking.computerName = hostName;
  networking.localHostName = hostName;

  # Application Layer Firewall.
  networking.applicationFirewall = {
    enable = true;
    blockAllIncoming = false;
    enableStealthMode = false;
    allowSigned = true;
  };

  # Enable Touch ID for sudo (requires physical presence; does not work over remote).
  security.pam.services.sudo_local.touchIdAuth = true;

  # Homebrew integration needs the designated primary user account.
  system.primaryUser = currentUserName;

  # Ensure each managed user has a declarative account entry.
  users.users = builtins.listToAttrs (
    map (name: {
      name = name;
      value = {
        home = "/Users/${name}";
        shell = pkgs.zsh;
      };
    }) userList
  );

  home-manager = {
    # Reuse system package set so Home Manager and nix-darwin stay aligned.
    useGlobalPkgs = true;
    useUserPackages = true;

    users = builtins.listToAttrs (
      map (name: {
        name = name;
        value = mkManagedUser name;
      }) userList
    );
  };

  # Core CLI tools available to all users.
  environment.systemPackages = managedSystemPackages;

  # System-level activation (runs as root; no sudo needed).
  # Battery power settings via pmset.
  system.activationScripts.configureBatterySaver.text = ''
    if [ "$(uname)" = "Darwin" ] && [ -x /usr/bin/pmset ]; then
      echo "Applying lid-closed server-mode settings..." >&2
      /usr/bin/pmset -a disablesleep 1 lidwake 0 displaysleep 0 sleep 0 disksleep 0
      /usr/bin/pmset -a womp 1 powernap 1
      /usr/bin/pmset -c lowpowermode 0 autorestart 1 highpowermode 1

      # Verification: ensure womp is enabled
      if /usr/bin/pmset -g cap | /usr/bin/grep -q "womp 1"; then
        echo "Wake-on-Network (womp) verified as enabled" >&2
      else
        echo "[CRITICAL] Wake-on-Network (womp) failed to verify as ENABLED" >&2
      fi
    fi
  '';

  # ---------------------------------------------------------------------------
  # System Activation: Rosetta 2 & Arduino 1.8.19 (Intel)
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = ''
    # 1. Ensure Rosetta 2 is installed for Intel binary support
    if [ "$(/usr/bin/uname)" = "Darwin" ]; then
      if ! /usr/bin/pgrep -q oahd; then
        echo "Rosetta 2 not found. Installing..." >&2
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license || echo "Rosetta installation skipped." >&2
      fi
    fi

    # 2. Arduino IDE 1.8.19 Installation
    ARDUINO_APP="/Applications/Arduino.app"
    SHOULD_INSTALL=${if enableArduinoIDE then "1" else "0"}
    if [ "$SHOULD_INSTALL" = "1" ]; then
      if [ ! -d "$ARDUINO_APP" ]; then
        echo "Installing Arduino IDE 1.8.19 (Legacy ZIP)..." >&2
        TMP_DIR=$(/usr/bin/mktemp -d)

        # Exact verified legacy URL
        URL="https://downloads.arduino.cc/arduino-1.8.19-macosx.zip"

        if /usr/bin/curl -fsSL -o "$TMP_DIR/arduino.zip" "$URL"; then
          /usr/bin/unzip -q "$TMP_DIR/arduino.zip" -d "$TMP_DIR"
          if [ -d "$TMP_DIR/Arduino.app" ]; then
            /bin/rm -rf "$ARDUINO_APP"
            /bin/mv "$TMP_DIR/Arduino.app" "$ARDUINO_APP"
            echo "  [SUCCESS] Arduino 1.8.19 deployed to /Applications." >&2
          fi
        else
          echo "  [ERROR] Failed to download Arduino 1.8.19." >&2
        fi
        /bin/rm -rf "$TMP_DIR"
      fi
    else
      if [ -d "$ARDUINO_APP" ]; then
        echo "Removing Arduino IDE (enableArduinoIDE is false)..." >&2
        /bin/rm -rf "$ARDUINO_APP"
      fi
    fi

    # 3. Enable Universal Clipboard & Handoff via UserActivityD
    echo "Ensuring iCloud Sync Services are initialized..." >&2
    /usr/bin/defaults write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true
    /usr/bin/defaults write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true

    # 4. iCloud security services intent
    /usr/bin/defaults write com.apple.icloud.findmydevice.notbackedup "FindMyMac" -bool true || true
    /usr/bin/defaults write com.apple.security.cloudkeychainproxy.notbackedup "KeychainSync" -bool true || true
  '';

  # Battery charge limit via bclm (SMC). Falls back gracefully on macOS 15+ where bclm is blocked.
  system.activationScripts.configureChargeLimit.text = ''
    if [ -x "/opt/homebrew/bin/bclm" ]; then
      echo "Ensuring battery charge limit is set to 100%..." >&2
      /opt/homebrew/bin/bclm write 100 || echo "[ERROR] bclm write failed" >&2
      /opt/homebrew/bin/bclm persist || echo "[ERROR] bclm persist failed" >&2
    else
      echo "[ERROR] bclm not found at /opt/homebrew/bin/bclm (may be blocked on macOS 15+)" >&2
    fi
  '';

  # Clear ColorSync device cache so displays re-detect their built-in profiles.
  system.activationScripts.configureMonitorColorProfile.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      if /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache 2>/dev/null; then
        echo "ColorSync device cache cleared." >&2
      else
        echo "  [INFO] ColorSync device cache may not exist or already cleared; continuing." >&2
      fi
    fi
  '';

  # Disable automatic diagnostic submission (requires manual user consent).
  system.activationScripts.configureDiagnostics.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults write /Library/Preferences/com.apple.SubmitDiagInfo SubmitDiagInfo -bool true
    fi
  '';

  # Set sudo timeout to 5 minutes.
  system.activationScripts.configureSudoTimeout.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      echo "Defaults timestamp_timeout=5" > /etc/sudoers.d/10-timeout
      chmod 440 /etc/sudoers.d/10-timeout
    fi
  '';

  # Lock screen message (system-level, requires root).
  system.activationScripts.configureLockScreenMessage.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults write /Library/Preferences/com.apple.loginwindow LoginwindowText "✨"
    fi
  '';

  # Keyboard backlight brightness set to 25%.
  system.activationScripts.configureKeyboardBrightness.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      echo "Setting keyboard backlight brightness to 25%..." >&2
      if ! /usr/bin/sudo /usr/bin/defaults write /Library/Preferences/com.apple.iokit.AmbientLightSensor "Keyboard Backlight Error Condition" -int 25; then
        echo "[ERROR] Failed to set keyboard backlight brightness." >&2
      fi
    fi
  '';

  homebrew = {
    enable = true;

    # Apply updates during activation so the machine does not drift.
    onActivation.autoUpdate = true;
    onActivation.cleanup = "zap";
    onActivation.upgrade = true;

    taps = allTaps;
    brews = managedBrews;
    casks = managedCasks;
  };

  # Nixvim provides declarative Neovim, LSP, and plugin setup.
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    plugins = {
      lsp = {
        enable = true;
        servers.rust_analyzer = {
          enable = true;

          # Use compiler/toolchain from rustup or per-project dev shells.
          installCargo = false;
          installRustc = false;
        };
      };

      lualine.enable = true;
      telescope.enable = true;
      treesitter.enable = true;
      web-devicons.enable = true;
    };
  };

  # Auto-load per-project environment via .envrc.
  programs.zsh.interactiveShellInit = ''eval "$(direnv hook zsh)"'';
}
