# macbook/defaults.nix — Declarative macOS system.defaults for the MacBook.
#
# All settings are applied by nix-darwin via the `defaults write` mechanism
# during `darwin-rebuild switch`.  They are grouped below by subsystem.
{ ... }:
let
  # ---------------------------------------------------------------------------
  # Input method definitions
  # The HIToolbox AppleEnabledInputSources list must be a complete ordered set;
  # the first entry is used as the default source at login.
  # ---------------------------------------------------------------------------

  # Traditional Cangjie input method (part of the macOS TCIM bundle).
  cangjieInputMethod = {
    "Bundle ID" = "com.apple.inputmethod.TCIM";
    InputSourceKind = "Input Method";
    "Input Method Identifier" = "com.apple.inputmethod.TCIM.Cangjie";
  };

  # Standard US QWERTY keyboard layout.
  usKeyboard = {
    InputSourceKind = "Keyboard Layout";
    "Keyboard Layout ID" = 0;
    "Keyboard Layout Name" = "U.S.";
  };

  # Ordered list: US keyboard first (default at login), Cangjie second.
  inputMethods = [
    usKeyboard
    cangjieInputMethod
  ];
in
{
  system.defaults = {
    # -------------------------------------------------------------------------
    # NSGlobalDomain — system-wide defaults written to the global preferences
    # domain, affecting most applications unless they override the value.
    # -------------------------------------------------------------------------
    NSGlobalDomain = {
      AppleFontSmoothing = 0;                        # disable subpixel anti-aliasing (better on Retina)
      AppleICUForce24HourTime = true;                # 24-hour clock regardless of locale
      AppleInterfaceStyleSwitchesAutomatically = true; # auto Dark/Light based on time of day
      AppleKeyboardUIMode = 2;                       # full keyboard access: Tab navigates all controls
      ApplePressAndHoldEnabled = false;              # disable character accent popup; enables key repeat
      AppleScrollerPagingBehavior = true;            # clicking scroll track jumps to clicked position
      AppleShowScrollBars = "Always";                # always show scroll bars (not just on scroll)
      InitialKeyRepeat = 15;                         # delay before key repeat starts (lower = faster)
      KeyRepeat = 2;                                 # key repeat rate (lower = faster)
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;    # disable -- → em-dash substitution
      NSAutomaticPeriodSubstitutionEnabled = false;  # disable double-space → period substitution
      NSAutomaticQuoteSubstitutionEnabled = false;   # disable "smart" quote substitution
      NSAutomaticSpellingCorrectionEnabled = false;
      NSAutomaticWindowAnimationsEnabled = false;    # disable new-window zoom animation
      NSNavPanelExpandedStateForSaveMode = true;     # open save dialogs in expanded mode by default
      NSNavPanelExpandedStateForSaveMode2 = true;
      NSTableViewDefaultSizeMode = 3;                # medium row height in table views
      PMPrintingExpandedStateForPrint = true;        # open print dialogs in expanded mode
      PMPrintingExpandedStateForPrint2 = true;
      "com.apple.keyboard.fnState" = true;           # Fn keys act as standard F1–F12 by default
      "com.apple.mouse.tapBehavior" = 1;             # tap-to-click on trackpad/mouse
      "com.apple.springing.delay" = 0.0;             # spring-loaded folders open instantly
      "com.apple.swipescrolldirection" = true;       # natural (reversed) scroll direction
      "com.apple.trackpad.scaling" = 3.0;            # maximum trackpad tracking speed
    };

    # -------------------------------------------------------------------------
    # CustomUserPreferences — arbitrary per-app defaults not exposed as
    # first-class nix-darwin options.  Written with `defaults write <domain>`.
    # -------------------------------------------------------------------------
    CustomUserPreferences = {
      # NSGlobalDomain: global preferences that don't fit nix-darwin typed options.
      "NSGlobalDomain" = {
        # Keep Finder context-menu Services at the default threshold so core
        # entries such as "New Terminal at Folder" remain discoverable from a
        # right-click without requiring keyboard-only fallbacks.
        # This key is not exposed by nix-darwin's typed options.
        NSServicesMinimumItemCountForContextSubmenu = 0;

        # Make toolbar title rollover hints appear instantly. This key is
        # currently outside nix-darwin's typed NSGlobalDomain option set.
        NSToolbarTitleViewRolloverDelay = 0.0;

        # Ensure fullscreen exit button is always visible when a window is
        # fullscreened in Stage Manager, so users can easily return to windowed
        # mode. Set to false to show the standard prominent fullscreen button
        # instead of letting macOS hide it when it deems it "optimized" away.
        NSWindowFullScreenButtonOptimized = false;

        # Text substitution dictionary that suppresses autocorrect for
        # technical terms and product names used frequently in this setup.
        # This key is not available as a typed nix-darwin NSGlobalDomain
        # option, so it is declared as a custom preference payload.
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
          { replace = "OneDrive"; "with" = "OneDrive"; }
          { replace = "pullback"; "with" = "pullback"; }
          { replace = "pushforward"; "with" = "pushforward"; }
          { replace = "SynthID"; "with" = "SynthID"; }
        ];

        # Treat Caps Lock as a per-app input-source switch (e.g. EN ↔ Cangjie).
        TISCapslockLanguageSwitch = true;
      };

      # Activity Monitor: show CPU usage in the Dock icon; refresh every second.
      "com.apple.ActivityMonitor" = {
        IconType = 5;         # CPU history graph in Dock icon
        UpdatePeriod = 1;     # refresh interval in seconds
      };

      # Opt out of Apple personalised advertising.
      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };

      # Trackpad: silent click (ActuationStrength 0), lightest click threshold,
      # force-touch feedback enabled, three-finger drag instead of Mission Control.
      "com.apple.AppleMultitouchTrackpad" = {
        ActuationStrength = 0;        # silent (haptic-only) click feedback
        FirstClickThreshold = 0;      # lightest click force required
        ForceSuppressed = false;      # keep Force Touch / Haptic Feedback enabled
        TrackpadThreeFingerDrag = true; # drag windows with three fingers
      };

      # Keyboard backlight: auto-adjust brightness; dim after 5 s of inactivity.
      "com.apple.BezelServices" = {
        dAuto = true;   # auto-adjust keyboard backlight to ambient light
        kDim = true;    # dim keyboard backlight when idle
        kDimTime = 5;   # dim after 5 seconds
      };

      # Input sources: set the full ordered list of enabled input methods,
      # select the first one (US keyboard) as the active source, and configure
      # dictation and keyboard behaviour.
      "com.apple.HIToolbox" = {
        AppleDictationAutoEnable = true;    # auto-enable dictation system-wide
        AppleEnabledInputSources = inputMethods;
        AppleSelectedInputSources = [ (builtins.head inputMethods) ];
      };

      # Disable the Gatekeeper quarantine flag that shows "Downloaded from the
      # Internet" dialogs for files opened from other machines / archives.
      "com.apple.LaunchServices" = {
        LSQuarantine = false;
      };

      # iCloud Photos: enable library sync and automatic import.
      "com.apple.Photos" = {
        CloudPhotosEnabled = 1;
        ImportToCloudEnabled = 1;
      };

      # Siri: enable keyboard shortcut (Option+Space = 1), hide menu-bar chrome
      # for a cleaner UI, and keep Type to Siri enabled for fast access.
      "com.apple.Siri" = {
        KeyboardShortcut = 1;      # Option+Space invokes Siri
        StatusMenuVisible = false; # hide Siri from the menu bar; shortcut remains available
        TypeToSiriEnabled = true;  # type queries instead of speaking them
      };

      # Software Update: check for and download updates automatically; install
      # critical (security) updates without prompting.
      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        AutomaticDownload = true;
        CriticalUpdateInstall = true;
      };

      # Hide the Spotlight menu-bar button to reduce persistent chrome while
      # preserving keyboard launch via Cmd+Space and launcher parity via
      # Raycast. This key is not exposed by nix-darwin typed options.
      "com.apple.Spotlight" = {
        MenuItemHidden = 1;
      };

      # TextEdit: default to plain text mode instead of RTF.
      "com.apple.TextEdit" = {
        RichText = false;
      };

      # Keyboard: Fn key acts as standard function keys (F1–F12) by default.
      "com.apple.TextInput.Kybd".FnKeyUsage = 1;

      # Show the Input Menu (language switcher) in the menu bar.
      "com.apple.TextInputMenu".visible = true;

      # Voice Memos: always record at uncompressed (lossless) quality.
      # RCVoiceMemosAudioQualityKey controls recording format:
      #   0 = AAC (compressed) — the factory default, trades quality for file size
      #   1 = Uncompressed (AIFF/WAV lossless) — preferred here because recordings
      #       retain full fidelity for archival, transcription, and re-export; any
      #       lossy transcoding can be done downstream on a copy without degrading
      #       the original capture.
      # Voice Memos is Apple-only; no Windows/NixOS equivalent exists.
      "com.apple.VoiceMemos" = {
        RCVoiceMemosAudioQualityKey = 1;
      };

      # Window Manager: enable click-to-show-desktop, hide Stage Manager widgets
      # for lower visual noise, and keep window tiling enabled (macOS 15+).
      "com.apple.WindowManager" = {
        EnableStandardClickToShowDesktop = true;
        StandardHideWidgets = true;   # hide Stage Manager widget strip to reduce persistent chrome
        WindowTilingEnabled = true;   # enable drag-to-edge window tiling (Sequoia)
      };

      # Siri / dictation backend preferences.
      "com.apple.assistant.support" = {
        "Assistant Enabled" = true;
        "Auto Punctuation Enabled" = true;   # insert punctuation during dictation
        "Dictation Enabled" = true;
        "Siri Data Sharing Opt-In Status" = 1; # opt in to Siri improvement program
      };

      # App Store: enable automatic app updates.
      "com.apple.commerce" = {
        AutoUpdate = true;
      };

      # Control Centre: show battery percentage; tighten status-item spacing.
      "com.apple.controlcenter" = {
        BatteryShowPercentage = true;
        NSStatusItemSelectionPadding = 6; # pixels of padding around selected item
        NSStatusItemSpacing = 6;          # pixels between status items
      };

      # Prevent macOS from writing .DS_Store files on network and removable
      # volumes. macOS does not provide an equivalent supported toggle for local
      # APFS/HFS+ folders.
      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };

      # Dock: disable Stage Manager / Widget corner zones (value 0 = no-op).
      "com.apple.dock" = {
        wdev-bl = 0;
        wdev-br = 0;
        wdev-tl = 0;
        wdev-tr = 0;
      };

      # Finder: allow text selection in Quick Look previews.
      "com.apple.finder" = {
        # Keep Desktop and Documents in iCloud Drive. These knobs are not
        # currently part of nix-darwin's typed `system.defaults.finder` set,
        # so they are expressed as custom domain values.
        FXICloudDriveDesktop = true;
        FXICloudDriveDocuments = true;

        # Keep the empty-trash confirmation prompt enabled. This key is not a
        # typed nix-darwin finder option, so we set it as a custom default.
        WarnOnEmptyTrash = true;

        QLEnableTextSelection = true;
      };

      # Menu bar clock: full date + time with seconds.
      "com.apple.menuextra.clock" = {
        DateFormat = "EEE y-MM-dd HH:mm:ss";
        ShowDate = 1;
        ShowDayOfWeek = true;
        ShowSeconds = true;
      };

      # Screensaver: require password immediately after the screensaver engages.
      "com.apple.screensaver" = {
        askForPassword = true;
        askForPasswordDelay = 0; # seconds before password is required (0 = immediately)
      };

      # Sidebar: show iCloud Drive entries in Finder sidebar.
      "com.apple.sidebarlists" = {
        showicloud = true;
      };

      # Dictation shortcut: double-press Right Command key (value 2).
      "com.apple.speech.recognition.AppleSpeechRecognition.prefs" = {
        DictationShortcut = 2;
      };

      # Mission Control: span desktops across multiple displays so every monitor
      # follows the same active Space when switching desktops.
      "com.apple.spaces" = {
        "spans-displays" = true;
      };

      # Spotlight: ordered search result categories with web/suggestions enabled
      # so search surfaces maximum context instead of hiding result classes.
      "com.apple.spotlight" = {
        orderedItems = [
          { enabled = true;  name = "APPLICATIONS"; }
          { enabled = true;  name = "SYSTEM_SETTINGS"; }
          { enabled = true;  name = "DIRECTORIES"; }
          { enabled = true;  name = "PDF"; }
          { enabled = true;  name = "FONTS"; }
          { enabled = true;  name = "DOCUMENTS"; }
          { enabled = true;  name = "MESSAGES"; }
          { enabled = true;  name = "CONTACTS"; }
          { enabled = true;  name = "EVENT_TODO"; }
          { enabled = true;  name = "IMAGES"; }
          { enabled = true;  name = "BOOKMARKS"; }
          { enabled = true;  name = "MUSIC"; }
          { enabled = true;  name = "MOVIES"; }
          { enabled = true;  name = "PRESENTATIONS"; }
          { enabled = true;  name = "SPREADSHEETS"; }
          { enabled = true;  name = "SOURCE"; }
          { enabled = true;  name = "MENU_SUGGESTIONS"; }
          { enabled = true;  name = "MENU_WEBSEARCH"; }
        ];
      };

      # Terminal: focus follows mouse pointer (hover to focus without clicking).
      "com.apple.terminal" = {
        FocusFollowsMouse = "YES";
      };

      # Universal Control: automatically connect to nearby Mac/iPad.
      "com.apple.universalcontrol" = {
        autoConnect = true;
      };

      # BetterDisplay: launch at login, show resolutions as a flat list, use
      # maximum native resolution by default.
      "com.betterdisplay" = {
        LaunchAtLogin = true;
        ShowResolutionsAsList = true;
        UseMaximumResolution = true;
      };

      # iTerm2: allow clipboard access from terminal applications, enable the
      # bootstrap daemon (supports shell integration without requiring a full
      # app launch), disable in-app update checks because updates are managed
      # declaratively, suppress the tip-of-the-day feature and its first-launch
      # permission prompt so fresh sessions are never interrupted, suppress the
      # secure-keyboard-entry/open-command warning, keep Secure Keyboard Entry
      # enabled, and enable the Finder service so "Open in iTerm" appears in
      # Finder right-click context menu.
      "com.googlecode.iterm2" = {
        "AllowClipboardAccess" = true;
        "BootstrapDaemon" = true;
        "EnableFindersService" = true;   # enable "Open in iTerm" in Finder
        # Pre-answer the first-launch "may we show you tips?" permission prompt
        # so iTerm2 never shows that dialog on a fresh provision.  Combining
        # PermissionToShowTip=true with TipOfTheDay=false simulates the state
        # where the user already answered yes to the prompt but then disabled
        # tips in preferences, preventing any re-prompt on subsequent launches.
        "NoSyncPermissionToShowTip" = true;
        "NoSyncTipOfTheDay" = false;
        "Secure Input" = true;  # blocks other processes from reading keystrokes
        "SUCheckAtStartup" = false;
        "SUEnableAutomaticChecks" = false;
        "WarnAboutSecureKeyboardInputWithOpenCommand" = false;
      };
    };

    # -------------------------------------------------------------------------
    # Dock settings
    # -------------------------------------------------------------------------
    dock = {
      autohide = true;               # hide Dock chrome by default; summon on edge hover
      expose-group-apps = true;      # Mission Control groups windows by application
      largesize = 128;               # magnified icon size when hovering
      launchanim = true;             # animate app icons on launch
      magnification = true;          # magnify icons under the cursor
      mineffect = "scale";           # window minimize animation: scale (no genie)
      minimize-to-application = true; # minimized windows collapse into app icon
      mru-spaces = false;            # do not reorder Spaces by recent use
      orientation = "bottom";        # Dock position
      show-recents = false;          # hide recents section to keep Dock focused on deliberate pins
      static-only = true;            # keep Dock scoped to active apps only for minimal persistent chrome
      tilesize = 128;                # base icon size
    };

    # -------------------------------------------------------------------------
    # Finder settings
    # -------------------------------------------------------------------------
    finder = {
      _FXShowPosixPathInTitle = true;        # show full POSIX path in title bar
      AppleShowAllFiles = true;              # always show hidden files in Finder
      AppleShowAllExtensions = true;         # always show file extensions
      CreateDesktop = true;                  # allow files/icons on the Desktop
      FXDefaultSearchScope = "SCcf";         # default search scope: current folder
      FXEnableExtensionChangeWarning = false; # suppress extension-change dialog friction for power workflows
      FXPreferredViewStyle = "clmv";         # default view: column view
      FXRemoveOldTrashItems = true;          # auto-prune Trash after 30 days to reduce maintenance clutter
      ShowExternalHardDrivesOnDesktop = true;
      ShowHardDrivesOnDesktop = true;
      ShowMountedServersOnDesktop = true;
      ShowPathbar = true;                    # show path breadcrumb bar at bottom
      ShowRemovableMediaOnDesktop = true;
      ShowStatusBar = true;                  # show item count / available space bar
    };

    # -------------------------------------------------------------------------
    # CustomSystemPreferences — arbitrary system-level defaults not exposed as
    # first-class nix-darwin options.  Written with `sudo defaults write`.
    # -------------------------------------------------------------------------
    CustomSystemPreferences = {
      # Enable automatic crash-report and diagnostic submission to Apple.
      "com.apple.SubmitDiagInfo".SubmitDiagInfo = true;

      # Ambient-light-sensor threshold that drives keyboard backlight brightness.
      # 25 maps to roughly half brightness in subdued lighting conditions.
      "com.apple.iokit.AmbientLightSensor"."Keyboard Backlight Error Condition" = 25;
    };

    # -------------------------------------------------------------------------
    # loginwindow — login-screen presentation settings.
    # -------------------------------------------------------------------------
    loginwindow.LoginwindowText = "✨";

    # -------------------------------------------------------------------------
    # Screenshot settings
    # -------------------------------------------------------------------------
    screencapture = {
      disable-shadow = true;    # omit window drop-shadow from screenshots
      location = "~/Desktop";   # default save location
      type = "png";             # default file format
    };

    # -------------------------------------------------------------------------
    # Trackpad settings (system-level; fine-grained per-app settings are in
    # CustomUserPreferences.com.apple.AppleMultitouchTrackpad above)
    # -------------------------------------------------------------------------
    trackpad = {
      Clicking = true;              # tap to click
      TrackpadThreeFingerDrag = true; # drag windows with three fingers
    };
  };
}
