{ ... }:
let
  cangjieInputMethod = {
    "Bundle ID" = "com.apple.inputmethod.TCIM";
    InputSourceKind = "Input Method";
    "Input Method Identifier" = "com.apple.inputmethod.TCIM.Cangjie";
  };

  usKeyboard = {
    InputSourceKind = "Keyboard Layout";
    "Keyboard Layout ID" = 0;
    "Keyboard Layout Name" = "U.S.";
  };

  inputMethods = [
    usKeyboard
    cangjieInputMethod
  ];
in
{
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
}
