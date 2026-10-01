# MacBook/defaults.nix - declarative macOS system.defaults for the MacBook.
{
  lib,
  repoRoot,
  username,
  ...
}:
let
  effectiveUsername = username;
  overlay = (import ../../modules/lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  # HIToolbox needs the complete ordered list; the first entry is the login default.
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

  # Word list from src/users/<user>/autocorrect/wordlist.txt (the default
  # template is empty). Identity substitutions, so the words stay unchanged.
  # check-suppress:config-method: method 3 (merge / defaults-based) -- not Method 1 (symlink) because macOS
  # NSUserDictionaryReplacementItems is managed via the `defaults` system
  # preference store, not a file path. There is no file to symlink. The value
  # is read from wordlist.txt at Nix eval time and written into the defaults
  # domain during darwin-rebuild.
  autocorrectWords = builtins.filter (w: w != "") (
    builtins.filter builtins.isString (
      # check-suppress:config-method: method 4 (runtime embedded at eval time) -- wordlist.txt is read at Nix evaluation time and embedded into the Nix store. No deployment step needed.
      builtins.split "\n" (builtins.readFile (overlay.selectFile "autocorrect" "wordlist.txt"))
    )
  );
in
{
  system.defaults = {
    NSGlobalDomain = {
      AppleFontSmoothing = 0; # disable subpixel anti-aliasing (better on Retina)
      AppleICUForce24HourTime = true; # 24-hour clock regardless of locale
      AppleInterfaceStyleSwitchesAutomatically = true; # auto Dark/Light based on time of day
      AppleKeyboardUIMode = 2; # full keyboard access: Tab navigates all controls
      ApplePressAndHoldEnabled = false; # disable character accent popup; enables key repeat
      AppleScrollerPagingBehavior = true; # clicking scroll track jumps to clicked position
      AppleShowScrollBars = "Always"; # always show scroll bars (not just on scroll)
      InitialKeyRepeat = 15; # delay before key repeat starts (lower = faster)
      KeyRepeat = 2; # key repeat rate (lower = faster)
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false; # disable -- → em-dash substitution
      NSAutomaticPeriodSubstitutionEnabled = false; # disable double-space → period substitution
      NSAutomaticQuoteSubstitutionEnabled = false; # disable "smart" quote substitution
      NSAutomaticSpellingCorrectionEnabled = false;
      NSAutomaticWindowAnimationsEnabled = false; # disable new-window zoom animation
      NSNavPanelExpandedStateForSaveMode = true; # open save dialogs in expanded mode by default
      NSNavPanelExpandedStateForSaveMode2 = true;
      NSTableViewDefaultSizeMode = 3; # medium row height in table views
      PMPrintingExpandedStateForPrint = true; # open print dialogs in expanded mode
      PMPrintingExpandedStateForPrint2 = true;
      "com.apple.keyboard.fnState" = true; # Fn keys act as standard F1–F12 by default
      "com.apple.mouse.tapBehavior" = 1; # tap-to-click on trackpad/mouse
      "com.apple.springing.delay" = 0.0; # spring-loaded folders open instantly
      "com.apple.swipescrolldirection" = true; # natural (reversed) scroll direction
      "com.apple.trackpad.scaling" = 3.0; # maximum trackpad tracking speed
    };

    CustomUserPreferences = {
      "NSGlobalDomain" = {
        NSQuitAlwaysKeepsWindows = true;

        # Keep the Finder Services threshold at the default so entries like
        # "New Terminal at Folder" stay on the right-click menu.
        NSServicesMinimumItemCountForContextSubmenu = 0;

        NSToolbarTitleViewRolloverDelay = 0.0;

        # Word list from src/users/<username>/autocorrect/wordlist.txt (default
        # template is empty). Identity substitutions leave the words unchanged.
        NSUserDictionaryReplacementItems = builtins.map (w: {
          replace = w;
          "with" = w;
        }) autocorrectWords;

        TISCapslockLanguageSwitch = true;
      };

      "com.apple.ActivityMonitor" = {
        IconType = 5; # CPU history graph in Dock icon
        UpdatePeriod = 1; # refresh interval in seconds
      };

      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };

      "com.apple.AppleMultitouchTrackpad" = {
        ActuationStrength = 0; # silent (haptic-only) click feedback
        FirstClickThreshold = 0; # lightest click force required
        ForceSuppressed = false; # keep Force Touch / Haptic Feedback enabled
        TrackpadThreeFingerDrag = true; # drag windows with three fingers
      };

      "com.apple.BezelServices" = {
        dAuto = true; # auto-adjust keyboard backlight to ambient light
        kDim = true; # dim keyboard backlight when idle
        kDimTime = 5; # dim after 5 seconds
      };

      # iCloud: a full local mirror instead of offloading. An activation hook
      # runs `brctl download` for every file at apply time. macOS ignores
      # OptimizeStorage when storage is smaller than the iCloud total, and
      # updates or cache clears can re-index files as cloud-only; `brctl
      # download` is the recovery.
      "com.apple.CloudDocs" = {
        BRCloudDriveSyncingEnabled = true; # enable iCloud Drive syncing
        OptimizeStorage = false; # disable "Optimize Mac Storage"
      };

      "com.apple.HIToolbox" = {
        AppleDictationAutoEnable = true; # auto-enable dictation system-wide
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

      # Siri here opens text input, so it does not collide with Raycast's
      # Option+Space.
      "com.apple.Siri" = {
        KeyboardShortcut = 3; # 3 = double-press Command: invoke Type to Siri
        StatusMenuVisible = false; # hide Siri from the menu bar; keep chrome minimal
        TypeToSiriEnabled = true; # type queries instead of speaking them
      };

      "com.apple.SoftwareUpdate" = {
        AllowPreReleaseInstallation = false; # disable beta / pre-release macOS updates
        AutomaticCheckEnabled = true;
        AutomaticDownload = true;
        AutomaticallyInstallMacOSUpdates = true; # auto-install macOS version updates
        ConfigDataInstall = true; # auto-install system data files and security responses
        CriticalUpdateInstall = true;
      };

      # Hidden UI only; the hotkey, indexing, and cache are handled by the
      # activation script disableSpotlightHotkey.
      "com.apple.Spotlight" = {
        MenuItemHidden = 1; # Hide menu-bar button
        FederatedSearchMaximumCount = 0; # Disable web search/suggestions
      };

      "com.apple.TextEdit" = {
        RichText = false;
      };

      "com.apple.TextInput.Kybd".FnKeyUsage = 1;

      "com.apple.TextInputMenu".visible = false;

      "com.apple.TextInputMenuAgent" = {
        "NSStatusItem VisibleCC Item-0" = 0;
      };

      "com.apple.VoiceMemos" = {
        RCVoiceMemosAudioQualityKey = 1;
      };

      "com.apple.WindowManager" = {
        EnableStandardClickToShowDesktop = true;
        StandardHideWidgets = true; # hide Stage Manager widget strip to reduce persistent chrome
        WindowTilingEnabled = true; # enable drag-to-edge window tiling (Sequoia)
      };

      "com.apple.assistant.support" = {
        "Assistant Enabled" = true;
        "Auto Punctuation Enabled" = true; # insert punctuation during dictation
        "Dictation Enabled" = true;
        "Siri Data Sharing Opt-In Status" = 1; # opt in to Siri improvement program
      };

      # These interrupt focus and offer limited value for power-user workflows.
      "com.apple.tips" = {
        LastSeenVersionForAutoStartTip = 99999; # mark all tips as already seen
        ShowTipOfTheDay = false; # disable daily tip notification entirely
      };

      "com.apple.commerce" = {
        AutoUpdate = true;
      };

      # Control Centre: hide the battery percentage (the allow-listed Stats app
      # shows it) and set status-item spacing to the 0 floor, with 4 as the
      # fallback when icons overlap.
      "com.apple.controlcenter" = {
        NSStatusItemSelectionPadding = 0; # pixels of padding around selected item
        NSStatusItemSpacing = 0; # pixels between status items
      };

      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };

      "com.apple.dock" = {
        wdev-bl = 0;
        wdev-br = 0;
        wdev-tl = 0;
        wdev-tr = 0;
      };

      # WHY the user domain: Finder reads these from ~/.Library/Preferences/
      # com.apple.finder.plist, so system.defaults.finder does not take effect.
      "com.apple.finder" = {
        # No typed nix-darwin finder option exists for this key.
        CreateDesktop = true; # allow files/icons on the Desktop
        ShowExternalHardDrivesOnDesktop = true; # show external drives on Desktop
        ShowHardDrivesOnDesktop = true; # show internal hard drives on Desktop
        ShowMountedServersOnDesktop = true; # show mounted NFS/SMB shares on Desktop
        ShowRemovableMediaOnDesktop = true; # show USB drives and optical media on Desktop

        FXICloudDriveDesktop = true;
        FXICloudDriveDocuments = true;

        # Not a typed nix-darwin finder option, hence the custom default.
        WarnOnEmptyTrash = true;

        DesktopViewSettings = {
          IconViewSettings = {
            arrangeBy = "grid";
            gridSpacing = 54;
            iconSize = 64;
            labelOnBottom = true;
            showItemInfo = false;
            textSize = 12;
          };
        };

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
        askForPasswordDelay = 0; # seconds before password is required (0 = immediately)
      };

      "com.apple.speech.recognition.AppleSpeechRecognition.prefs" = {
        DictationShortcut = 2;
      };

      "com.apple.spaces" = {
        "spans-displays" = true;
      };

      # WHY: most Raycast settings live in its SQLite database, not a plist, so
      # only documented plist keys are set here. Pop to Root timeout, Escape
      # behavior, navigation bindings, and Root Search Sensitivity need the
      # Raycast UI under Settings > Advanced.
      "com.raycast.macos" = {
        LaunchAtLogin = false; # Managed by nucleus autostart system
        Appearance = "system"; # Auto Dark/Light based on time of day
        WindowMode = "default"; # Use default window (not compact)
        ShowFavoritesInCompactMode = true; # Show favorites in compact mode

        UseSystemNetworkSettings = true; # Web proxy from macOS System Settings
        CertificatesProvider = "Keychain"; # Use Keychain for certificate validation

        FaviconProvider = "Raycast"; # Raycast's built-in favicon resolver

        DeveloperMode = true; # Enable development mode
        AutoReloadOnSave = true; # Auto-reload on script save
        # The other dev settings (Node production, logging, pop to root) are
        # database-only, so they stay in Settings > Advanced > Developer Tools.

      };
      "com.apple.terminal" = {
        FocusFollowsMouse = "YES";
      };

      "com.apple.universalcontrol" = {
        autoConnect = true;
      };

      # WHY: com.apple.iCloud.fmip.preferences is an internal Apple domain with
      # no public developer documentation; keys are empirically observed.
      "com.apple.iCloud.fmip.preferences" = {
        ArchiveVaultEnabled = 1;
      };

      # WHY nativeAutoBrightnessManagement stays off: with macOS auto
      # brightness also on, the two brightness owners fight and the panel
      # ratchets up with no user input (waydabber/BetterDisplay #4421, #5234,
      # mitigated by #4589). This host runs BetterDisplay for the HeadlessDisplay
      # virtual screen only. The @Display:2 suffix is the built-in panel tagID.
      "pro.betterdisplay.BetterDisplay" = {
        LaunchAtLogin = false;
        ShowResolutionsAsList = true;
        UseMaximumResolution = true;
        sendCrashReports = true;
        enableProfessionalFeatures = false;
        setDelay = 0.2;
        wakeDelay = 1.5;
        "nativeAutoBrightnessManagement@Display:2" = false;
        SUEnableAutomaticChecks = false;
        SUAutomaticallyUpdate = false;
        SUEnablePrerelease = false;
      };

      # WHY declare values that match upstream defaults: rebuilds then keep the
      # runtime behavior stable.
      "com.lwouis.alt-tab-macos" = {
        appearanceStyle = "2"; # titles
        appearanceSize = "3"; # auto
        appearanceTheme = "2"; # system
        shortcutStyle = "0"; # focus on release
        previewFocusedWindow = "false";

        showOnScreen = "1"; # screen including mouse

        shortcutCount = "2";
        holdShortcut = "⌥";
        nextWindowShortcut = "→";
        holdShortcut2 = "⌥";
        nextWindowShortcut2 = "`";

        appsToShow = "0"; # all apps
        spacesToShow = "0"; # all spaces
        screensToShow = "0"; # all screens
        showMinimizedWindows = "0"; # show
        showHiddenWindows = "0"; # show
        showFullscreenWindows = "0"; # show
        showWindowlessApps = "2"; # show at the end
        windowOrder = "0"; # recently focused first

        appsToShow2 = "1"; # active app
        spacesToShow2 = "0"; # all spaces
        screensToShow2 = "0"; # all screens
        showMinimizedWindows2 = "0"; # show
        showHiddenWindows2 = "0"; # show
        showFullscreenWindows2 = "0"; # show
        showWindowlessApps2 = "2"; # show at the end
        windowOrder2 = "0"; # recently focused first
        shortcutStyle2 = "0"; # focus on release
        previewFocusedWindow2 = "false";

        nextWindowGesture = "0"; # disabled
        appsToShow10 = "0"; # all apps (gesture profile)
        spacesToShow10 = "0"; # all spaces
        screensToShow10 = "0"; # all screens
        showMinimizedWindows10 = "0"; # show
        showHiddenWindows10 = "0"; # show
        showFullscreenWindows10 = "0"; # show
        showWindowlessApps10 = "2"; # show at the end
        windowOrder10 = "0"; # recently focused first
        shortcutStyle10 = "0"; # focus on release
        previewFocusedWindow10 = "false";

        arrowKeysEnabled = "true";
        vimKeysEnabled = "false";
        mouseHoverEnabled = "false";

        cursorFollowFocus = "0"; # never
        trackpadHapticFeedbackEnabled = "true";

        startAtLogin = "false";
        captureWindowsInBackground = "true";
        language = "0"; # system default
        updatePolicy = "0"; # do not check periodically
        crashPolicy = "2"; # always send crash reports
      };

      # iTerm2 app-level preferences, not per-profile settings.
      "org.linearmouse.LinearMouse" = {
        showInDock = true;
        launchAtLogin = false;
        SUEnableAutomaticChecks = false;
        SUAutomaticallyUpdate = false;
      };

      # iTerm2 app-level preferences (not per-profile settings).
      "com.googlecode.iterm2" = {
        # KEY_DEFAULT_GUID picks the profile for new windows and tabs when none
        # is selected.
        # check-suppress:config-method: method 1 (writable symlink) -- src/users/default/iterm2/DynamicProfiles/default-profile.json via iterm2.nix
        "Default Bookmark Guid" = "9B6E253F-0528-4F8A-A025-4FD279C73DB1";
        # Allow clipboard access from terminal applications.
        "AllowClipboardAccess" = true;
        # Supports shell integration without a full app launch.
        "BootstrapDaemon" = true;
        # Enable "Open in iTerm" Finder right-click context menu.
        "EnableFindersService" = true;
        # Pre-answer the first-launch tips prompt so a fresh provision goes
        # straight to showing tips.
        "NoSyncPermissionToShowTip" = true;
        "NoSyncTipOfTheDay" = true;
        # Blocks other processes from reading keystrokes.
        "Secure Input" = true;
        # Disable in-app update checks; updates are managed declaratively.
        "SUCheckAtStartup" = false;
        "SUEnableAutomaticChecks" = false;
        # The NeverWarnAboutShortLivedSessions_<GUID> key silences the
        # iTermWarning that fires when a session ends inside shortLivedSessionDuration.
        "NeverWarnAboutShortLivedSessions_743F1344-118A-4E38-8CB0-D7319D34EF8C" = true;
        "NeverWarnAboutShortLivedSessions_9B6E253F-0528-4F8A-A025-4FD279C73DB1" = true;
        # Suppress the secure-keyboard-entry warning when opening a command.
        "WarnAboutSecureKeyboardInputWithOpenCommand" = false;
      };

      # Amphetamine: declaratively enable the Power Protect install toggle.
      # WHY partial declarative only: upstream wants the helper script and a
      # sudoers fragment placed by hand, and this key activates that feature
      # path once they exist. Amphetamine is menu-bar-only by design
      # (LSUIElement), so it must never get a hide key.
      "com.if.Amphetamine" = {
        "Enable Power Protect Install" = true;
      };

      # WHY: held keys must repeat for vim motions (h/j/k/l) via vscode-neovim.
      "com.microsoft.VSCode" = {
        ApplePressAndHoldEnabled = false;
      };
      "com.microsoft.VSCodeInsiders" = {
        ApplePressAndHoldEnabled = false;
      };

      # Stats replaces the macOS battery item, so its icon must stay visible and
      # must never get a hide key.
      "eu.exelban.Stats" = { };
    };

    dock = {
      autohide = true; # hide Dock chrome by default; summon on edge hover
      expose-group-apps = true; # Mission Control groups windows by application
      largesize = 128; # magnified icon size when hovering
      launchanim = true; # animate app icons on launch
      magnification = true; # magnify icons under the cursor
      mineffect = "scale"; # window minimize animation: scale (no genie)
      minimize-to-application = true; # minimized windows collapse into app icon
      mru-spaces = false; # do not reorder Spaces by recent use
      orientation = "bottom"; # Dock position
      show-recents = false; # hide recents section to keep Dock focused on deliberate pins
      static-only = true; # keep Dock scoped to active apps only for minimal persistent chrome
      tilesize = 128; # base icon size
    };

    finder = {
      _FXShowPosixPathInTitle = true; # show full POSIX path in title bar
      AppleShowAllFiles = true; # always show hidden files in Finder
      AppleShowAllExtensions = true; # always show file extensions
      FXDefaultSearchScope = "SCcf"; # default search scope: current folder
      FXEnableExtensionChangeWarning = false; # suppress extension-change dialog friction for power workflows
      FXPreferredViewStyle = "clmv"; # default view: column view
      FXRemoveOldTrashItems = true; # auto-prune Trash; Apple default is 30 days (non-configurable boolean)
      ShowPathbar = true; # show path breadcrumb bar at bottom
      ShowStatusBar = true; # show item count / available space bar
    };

    # CustomSystemPreferences: arbitrary system-level defaults with no
    # first-class nix-darwin option, written with `sudo defaults write`.
    CustomSystemPreferences = {
      "com.apple.SubmitDiagInfo".SubmitDiagInfo = true;

      # 25 is roughly half brightness in subdued light. WHY the empirical values:
      # com.apple.iokit.AmbientLightSensor is a kernel IOKit domain with no
      # public Apple developer reference.
      "com.apple.iokit.AmbientLightSensor"."Keyboard Backlight Error Condition" = 25;
    };

    loginwindow.LoginwindowText = "✨";
    screencapture = {
      disable-shadow = true; # omit window drop-shadow from screenshots
      location = "~/Desktop"; # default save location
      # WHY the explicit target: keep clipboard-first capture as the default
      # while retaining a deterministic file-save location.
      target = "clipboard"; # default capture destination
      type = "png"; # default file format
    };

    trackpad = {
      Clicking = true; # tap to click
      TrackpadThreeFingerDrag = true; # drag windows with three fingers
    };
  };
}
