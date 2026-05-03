{ pkgs, username, ... }:
let
  enableArduinoIDE = true;

  cangjieInputMethod = {
    "Bundle ID" = "com.apple.inputmethod.TCIM";
    InputSourceKind = "Input Method";
    "Input Method Identifier" = "com.apple.inputmethod.TCIM.Cangjie";
  };

  managedBrews = [
    "displayplacer"
    "smudge/smudge/nightlight"
    "zackelia/formulae/bclm"
  ];

  managedCasks = [
    "alt-tab"
    "appcleaner"
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
    "parsec"
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

  managedSystemPackages = [
    (pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ]))
  ];

  usKeyboard = {
    InputSourceKind = "Keyboard Layout";
    "Keyboard Layout ID" = 0;
    "Keyboard Layout Name" = "U.S.";
  };

  inputMethods = [
    usKeyboard
    cangjieInputMethod
  ];

  extractTap = item:
    let
      matches = builtins.match "(.*)/[^/]+" item;
    in
    if matches == null then null else builtins.elemAt matches 0;

  defaultTaps = [ "homebrew/cask" "homebrew/core" ];

  allTaps =
    let
      rawTaps = builtins.filter (x: x != null) (map extractTap (managedBrews ++ managedCasks));
      filtered = builtins.filter (tap: !(builtins.elem tap defaultTaps)) rawTaps;
    in
    builtins.foldl' (acc: tap: if builtins.elem tap acc then acc else acc ++ [ tap ]) [ ] filtered;
in
{
  imports = [ ../../modules/core.nix ];

  environment.systemPackages = managedSystemPackages;

  homebrew = {
    enable = true;

    onActivation.autoUpdate = true;
    onActivation.cleanup = "zap";
    onActivation.upgrade = true;

    taps = allTaps;
    brews = managedBrews;
    casks = managedCasks;
  };

  networking.applicationFirewall = {
    allowSigned = true;
    blockAllIncoming = false;
    enable = true;
    enableStealthMode = false;
  };

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";

  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  programs.zsh.enable = true;

  security.pam.services.sudo_local.touchIdAuth = true;

  sops = {
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    gnupg.home = "/Users/${username}/.gnupg";
  };

  system.activationScripts.configureBatteryPolicy.text = ''
    if [ "$(uname)" = "Darwin" ] && [ -x /usr/bin/pmset ]; then
      /usr/bin/pmset -a disablesleep 1 lidwake 0 displaysleep 0 sleep 0 disksleep 0
      /usr/bin/pmset -a womp 1 powernap 1
      /usr/bin/pmset -c autorestart 1 highpowermode 1 lowpowermode 0
    fi
  '';

  system.activationScripts.configureChargeLimit.text = ''
    if [ "$(uname)" = "Darwin" ] && [ -x /opt/homebrew/bin/bclm ]; then
      /opt/homebrew/bin/bclm write 100 || echo "[ERROR] bclm write failed" >&2
      /opt/homebrew/bin/bclm persist || echo "[ERROR] bclm persist failed" >&2
    fi
  '';

  system.activationScripts.configureDiagnostics.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults write /Library/Preferences/com.apple.SubmitDiagInfo SubmitDiagInfo -bool true
    fi
  '';

  system.activationScripts.configureKeyboardBrightness.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults write /Library/Preferences/com.apple.iokit.AmbientLightSensor "Keyboard Backlight Error Condition" -int 25 || true
    fi
  '';

  system.activationScripts.configureLockScreenMessage.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults write /Library/Preferences/com.apple.loginwindow LoginwindowText "✨"
    fi
  '';

  system.activationScripts.configureMonitorColorProfile.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache || true
    fi
  '';

  system.activationScripts.configurePostActivation.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      if ! /usr/bin/pgrep -q oahd; then
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license || true
      fi

      ARDUINO_APP="/Applications/Arduino.app"
      SHOULD_INSTALL=${if enableArduinoIDE then "1" else "0"}
      if [ "$SHOULD_INSTALL" = "1" ]; then
        if [ ! -d "$ARDUINO_APP" ]; then
          TMP_DIR=$(/usr/bin/mktemp -d)
          URL="https://downloads.arduino.cc/arduino-1.8.19-macosx.zip"
          if /usr/bin/curl -fsSL -o "$TMP_DIR/arduino.zip" "$URL"; then
            /usr/bin/unzip -q "$TMP_DIR/arduino.zip" -d "$TMP_DIR"
            if [ -d "$TMP_DIR/Arduino.app" ]; then
              /bin/rm -rf "$ARDUINO_APP"
              /bin/mv "$TMP_DIR/Arduino.app" "$ARDUINO_APP"
            fi
          fi
          /bin/rm -rf "$TMP_DIR"
        fi
      else
        [ -d "$ARDUINO_APP" ] && /bin/rm -rf "$ARDUINO_APP"
      fi
    fi
  '';

  system.activationScripts.configureSudoTimeout.text = ''
    if [ "$(uname)" = "Darwin" ]; then
      echo "Defaults timestamp_timeout=5" > /etc/sudoers.d/10-timeout
      chmod 440 /etc/sudoers.d/10-timeout
    fi
  '';

  system.defaults = {
    NSGlobalDomain = {
      AppleFontSmoothing = 0;
      AppleICUForce24HourTime = true;
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleKeyboardUIMode = 2;
      ApplePressAndHoldEnabled = false;
      AppleScrollerPagingBehavior = true;
      AppleShowScrollBars = "Always";
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
      NSAutomaticWindowAnimationsEnabled = false;
      NSNavPanelExpandedStateForSaveMode = true;
      NSNavPanelExpandedStateForSaveMode2 = true;
      NSServicesMinimumItemCountForContextSubmenu = 9999;
      NSTableViewDefaultSizeMode = 3;
      NSToolbarTitleViewRolloverDelay = 0.0;
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
      PMPrintingExpandedStateForPrint = true;
      PMPrintingExpandedStateForPrint2 = true;
      "com.apple.keyboard.fnState" = true;
      "com.apple.mouse.tapBehavior" = 1;
      "com.apple.springing.delay" = 0.0;
      "com.apple.swipescrolldirection" = true;
      "com.apple.trackpad.scaling" = 3.0;
    };

    CustomUserPreferences = {
      "com.apple.ActivityMonitor" = {
        IconType = 5;
        UpdatePeriod = 1;
      };

      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };

      "com.apple.AppleMultitouchTrackpad" = {
        ActuationStrength = 0;
        FirstClickThreshold = 0;
        ForceSuppressed = false;
        TrackpadThreeFingerDrag = true;
      };

      "com.apple.BezelServices" = {
        dAuto = true;
        kDim = true;
        kDimTime = 5;
      };

      "com.apple.HIToolbox" = {
        AppleEnabledInputSources = inputMethods;
        AppleSelectedInputSources = [ (builtins.head inputMethods) ];
      };

      "com.apple.LaunchServices" = {
        LSQuarantine = false;
      };

      "com.apple.Photos" = {
        CloudPhotosEnabled = 1;
        ImportToCloudEnabled = 1;
      };

      "com.apple.Safari" = {
        AutoFillPasswords = false;
        IncludeDevelopMenu = true;
        IncludeInternalDebugMenu = true;
      };

      "com.apple.Siri" = {
        KeyboardShortcut = 1;
        StatusMenuVisible = false;
        TypeToSiriEnabled = true;
      };

      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        AutomaticDownload = true;
        CriticalUpdateInstall = true;
      };

      "com.apple.TextEdit" = {
        RichText = false;
      };

      "com.apple.TextInputMenu".visible = true;

      "com.apple.WindowManager" = {
        EnableStandardClickToShowDesktop = true;
        StandardHideWidgets = true;
        WindowTilingEnabled = true;
      };

      "com.apple.assistant.support" = {
        "Assistant Enabled" = true;
        "Auto Punctuation Enabled" = true;
        "Dictation Enabled" = true;
        "Siri Data Sharing Opt-In Status" = 1;
      };

      "com.apple.commerce" = {
        AutoUpdate = true;
      };

      "com.apple.controlcenter" = {
        BatteryShowPercentage = true;
        NSStatusItemSelectionPadding = 6;
        NSStatusItemSpacing = 6;
      };

      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };

      "com.apple.finder" = {
        QLEnableTextSelection = true;
      };

      "com.apple.menuextra.clock" = {
        DateFormat = "EEE y-MM-dd HH:mm:ss";
        ShowDate = 1;
        ShowDayOfWeek = true;
        ShowSeconds = true;
      };

      "com.apple.screensaver" = {
        askForPassword = true;
        askForPasswordDelay = 0;
      };

      "com.apple.sidebarlists" = {
        showicloud = true;
      };

      "com.apple.speech.recognition.AppleSpeechRecognition.prefs" = {
        DictationShortcut = 2;
      };

      "com.apple.spaces" = {
        "spans-displays" = false;
      };

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

      "com.apple.terminal" = {
        FocusFollowsMouse = "YES";
      };

      "com.apple.universalaccess" = {
        FontSizeCategory = "AX1";
        cursorSize = 1.33;
        reduceMotion = false;
        reduceTransparency = false;
        showWindowTitlebarIcons = true;
      };

      "com.apple.universalcontrol" = {
        autoConnect = true;
      };

      "com.betterdisplay" = {
        LaunchAtLogin = true;
        ShowResolutionsAsList = true;
        UseMaximumResolution = true;
      };

      "com.googlecode.iterm2" = {
        "AllowClipboardAccess" = true;
        "BootstrapDaemon" = true;
        "NoSyncTipOfTheDay" = false;
        "SUCheckAtStartup" = true;
        "SUEnableAutomaticChecks" = true;
        "SUFeedURL" = "https://iterm2.com/appcasts/testing_modern.xml";
        "Secure Input" = true;
      };
    };

    dock = {
      autohide = true;
      expose-group-by-app = true;
      largesize = 128;
      launchanim = true;
      magnification = true;
      mineffect = "scale";
      minimize-to-application = true;
      mru-spaces = false;
      orientation = "bottom";
      show-recents = false;
      static-only = true;
      tilesize = 128;
    };

    finder = {
      _FXShowPosixPathInTitle = true;
      AppleShowAllExtensions = true;
      CreateDesktop = true;
      FXDefaultSearchScope = "SCcf";
      FXEnableExtensionChangeWarning = false;
      FXICloudDriveDesktop = true;
      FXICloudDriveDocuments = true;
      FXPreferredViewStyle = "clmv";
      FXRemoveOldTrashItems = true;
      ShowExternalHardDrivesOnDesktop = true;
      ShowHardDrivesOnDesktop = true;
      ShowMountedServersOnDesktop = true;
      ShowPathbar = true;
      ShowRemovableMediaOnDesktop = true;
      ShowStatusBar = true;
      WarnOnEmptyTrash = true;
    };

    screencapture = {
      disable-shadow = true;
      location = "~/Desktop";
      type = "png";
    };

    trackpad = {
      Clicking = true;
      TrackpadThreeFingerDrag = true;
    };
  };

  system.primaryUser = username;
  system.stateVersion = 4;

  users.users.${username}.shell = pkgs.zsh;
}
