# MacBook/defaults.nix — Declarative macOS system.defaults for the MacBook.
#
# All settings are applied by nix-darwin via the `defaults write` mechanism
# during `darwin-rebuild switch`.  They are grouped below by subsystem.
{
  username,
  ...
}:
let
  effectiveUsername = username;
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
  overlay = (import ../../modules/lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

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

  # ---------------------------------------------------------------------------
  # Autocorrect suppression word list
  # Loaded from src/users/<user>/autocorrect/wordlist.txt (overlay; default is empty):
  # one word per line, sorted alphabetically. Identity substitutions (word → word)
  # prevent macOS from autocorrecting technical terms and product names.
  # check-suppress:config-method: method 3 (merge / defaults-based) -- not Method 1 (symlink) because macOS
  # NSUserDictionaryReplacementItems is managed via the `defaults` system
  # preference store, not a file path. There is no file to symlink. The value
  # is read from wordlist.txt at Nix eval time and written into the defaults
  # domain during darwin-rebuild.
  # This is macOS-only (no NixOS/Windows equivalent).
  # ---------------------------------------------------------------------------
  autocorrectWords = builtins.filter (w: w != "") (
    builtins.filter builtins.isString (
      # check-suppress:config-method: method 4 (runtime embedded at eval time) -- wordlist.txt is read at Nix evaluation time and embedded into the Nix store. No deployment step needed.
      builtins.split "\n" (builtins.readFile (overlay.selectFile "autocorrect" "wordlist.txt"))
    )
  );
in
{
  system.defaults = {
    # -------------------------------------------------------------------------
    # NSGlobalDomain — system-wide defaults written to the global preferences
    # domain, affecting most applications unless they override the value.
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # CustomUserPreferences — arbitrary per-app defaults not exposed as
    # first-class nix-darwin options.  Written with `defaults write <domain>`.
    # -------------------------------------------------------------------------
    CustomUserPreferences = {
      # NSGlobalDomain: global preferences that don't fit nix-darwin typed options.
      # Source: https://developer.apple.com/documentation/foundation/userdefaults
      "NSGlobalDomain" = {
        # Disable "Close windows when quitting an application" so that
        # macOS preserves and restores application windows across quit/launch
        # cycles. This key is not exposed by nix-darwin's typed options.
        # Sources:
        # https://macos-defaults.com/misc/nsquitalwayskeepwindows.html
        # https://apple.stackexchange.com/questions/411466
        NSQuitAlwaysKeepsWindows = true;

        # Keep Finder context-menu Services at the default threshold so core
        # entries such as "New Terminal at Folder" remain discoverable from a
        # right-click without requiring keyboard-only fallbacks.
        # This key is not exposed by nix-darwin's typed options.
        NSServicesMinimumItemCountForContextSubmenu = 0;

        # Make toolbar title rollover hints appear instantly. This key is
        # currently outside nix-darwin's typed NSGlobalDomain option set.
        NSToolbarTitleViewRolloverDelay = 0.0;

        # Text substitution dictionary that suppresses autocorrect for
        # technical terms and product names used frequently in this setup.
        # This key is not available as a typed nix-darwin NSGlobalDomain
        # option, so it is declared as a custom preference payload.
        # Source: https://developer.apple.com/documentation/foundation/userdefaults
        # Word list is loaded from the per-user autocorrect overlay — edit
        # src/users/<username>/autocorrect/wordlist.txt (default template is empty).
        # All entries are identity substitutions
        # (word → word) so macOS leaves them unchanged instead of autocorrecting.
        NSUserDictionaryReplacementItems = builtins.map (w: {
          replace = w;
          "with" = w;
        }) autocorrectWords;

        # Treat Caps Lock as a per-app input-source switch (e.g. EN ↔ Cangjie).
        # Source: https://developer.apple.com/documentation/inputmethodkit
        TISCapslockLanguageSwitch = true;
      };

      # Activity Monitor: show CPU usage in the Dock icon; refresh every second.
      # Source: https://support.apple.com/en-us/guide/activity-monitor/welcome/mac
      "com.apple.ActivityMonitor" = {
        IconType = 5; # CPU history graph in Dock icon
        UpdatePeriod = 1; # refresh interval in seconds
      };

      # Opt out of Apple personalised advertising.
      # Source: https://support.apple.com/en-us/guide/deployment/privacy-management-dep4db1d2fa4/web
      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };

      # Trackpad: silent click (ActuationStrength 0), lightest click threshold,
      # force-touch feedback enabled, three-finger drag instead of Mission Control.
      # Source: https://support.apple.com/en-us/guide/mac-help/change-trackpad-settings-on-mac-mh27502/mac
      "com.apple.AppleMultitouchTrackpad" = {
        ActuationStrength = 0; # silent (haptic-only) click feedback
        FirstClickThreshold = 0; # lightest click force required
        ForceSuppressed = false; # keep Force Touch / Haptic Feedback enabled
        TrackpadThreeFingerDrag = true; # drag windows with three fingers
      };

      # Keyboard backlight: auto-adjust brightness; dim after 5 s of inactivity.
      # Note: com.apple.BezelServices is an undocumented private preference domain;
      # keys are community-documented (no official Apple developer reference).
      "com.apple.BezelServices" = {
        dAuto = true; # auto-adjust keyboard backlight to ambient light
        kDim = true; # dim keyboard backlight when idle
        kDimTime = 5; # dim after 5 seconds
      };

      # iCloud: disable "Optimize Mac Storage" and enable syncing so macOS
      # maintains a full local mirror of iCloud Drive instead of offloading files
      # to the cloud when space is low. An activation hook forcibly downloads all
      # iCloud files via `brctl download` at apply-time to ensure local presence.
      # Constraints: (1) if physical storage < total iCloud size, macOS will
      # ignore OptimizeStorage; (2) system updates / cache clears can trigger
      # re-indexing, causing files to appear as cloud-only until re-downloaded;
      # (3) manual recovery available via `brctl download`. See AGENTS.md
      # security invariants for drift reset handling.
      # Source: https://support.apple.com/en-us/guide/mac-help/use-icloud-drive-to-store-files-mchle14b5f56/mac
      "com.apple.CloudDocs" = {
        BRCloudDriveSyncingEnabled = true; # enable iCloud Drive syncing
        OptimizeStorage = false; # disable "Optimize Mac Storage"
      };

      # Input sources: set the full ordered list of enabled input methods,
      # select the first one (US keyboard) as the active source, and configure
      # dictation and keyboard behaviour.
      # Source: https://developer.apple.com/documentation/inputmethodkit
      "com.apple.HIToolbox" = {
        AppleDictationAutoEnable = true; # auto-enable dictation system-wide
        AppleEnabledInputSources = inputMethods;
        AppleSelectedInputSources = [ (builtins.head inputMethods) ];
      };

      # Disable the Gatekeeper quarantine flag that shows "Downloaded from the
      # Internet" dialogs for files opened from other machines / archives.
      # Source: https://developer.apple.com/documentation/coreservices/launch_services
      "com.apple.LaunchServices" = {
        LSQuarantine = false;
      };

      # iCloud Photos: enable library sync and automatic import.
      # Source: https://support.apple.com/en-us/guide/photos/turn-on-icloud-photos-pht28a5bf4c/mac
      "com.apple.Photos" = {
        CloudPhotosEnabled = 1;
        ImportToCloudEnabled = 1;
      };

      # Siri: enable the double-press Command shortcut for Type to Siri so the
      # keyboard shortcut launches Siri in text-input mode. This does not
      # conflict with Raycast's Option+Space binding.
      # Source: https://support.apple.com/en-us/guide/mac-help/change-siri-settings-mh40630/mac
      "com.apple.Siri" = {
        KeyboardShortcut = 3; # 3 = double-press Command: invoke Type to Siri
        StatusMenuVisible = false; # hide Siri from the menu bar; keep chrome minimal
        TypeToSiriEnabled = true; # type queries instead of speaking them
      };

      # Software Update: check for and download updates automatically; install
      # critical (security) updates, macOS version updates, and system data files
      # without prompting. Pre-release / beta updates are explicitly disabled.
      # Source: https://support.apple.com/en-us/guide/deployment/manage-software-updates-depafd2fad80/web
      "com.apple.SoftwareUpdate" = {
        AllowPreReleaseInstallation = false; # disable beta / pre-release macOS updates
        AutomaticCheckEnabled = true;
        AutomaticDownload = true;
        AutomaticallyInstallMacOSUpdates = true; # auto-install macOS version updates
        ConfigDataInstall = true; # auto-install system data files and security responses
        CriticalUpdateInstall = true;
      };

      # Spotlight: disable completely to eliminate UI chrome and background indexing.
      # Raycast is the primary launcher; Spotlight adds no value and consumes resources.
      # Complete disabling happens in three stages:
      #   1. Hide UI (this plist section)
      #   2. Disable hotkey 61 (in macos.nix activation: disableSpotlightHotkey)
      #   3. Stop indexing + clear cache (in macos.nix activation: disableSpotlightHotkey)
      # Source: https://support.apple.com/en-us/guide/mac-help/search-with-spotlight-mchlp1090/mac
      "com.apple.Spotlight" = {
        MenuItemHidden = 1; # Hide menu-bar button
        FederatedSearchMaximumCount = 0; # Disable web search/suggestions
      };

      # TextEdit: default to plain text mode instead of RTF.
      # Source: https://support.apple.com/en-us/guide/textedit/use-plain-text-mode-txte1092/mac
      "com.apple.TextEdit" = {
        RichText = false;
      };

      # Keyboard: Fn key acts as standard function keys (F1–F12) by default.
      # Source: https://support.apple.com/en-us/guide/mac-help/keyboard-settings-mchlp1204/mac
      "com.apple.TextInput.Kybd".FnKeyUsage = 1;

      # Show the Input Menu (language switcher) in the menu bar.
      # Source: https://support.apple.com/en-us/guide/mac-help/type-in-another-language-mac-mh21578/mac
      "com.apple.TextInputMenu".visible = true;

      # Voice Memos: always record at uncompressed (lossless) quality.
      # RCVoiceMemosAudioQualityKey controls recording format:
      #   0 = AAC (compressed) — the factory default, trades quality for file size
      #   1 = Uncompressed (AIFF/WAV lossless) — preferred here because recordings
      #       retain full fidelity for archival, transcription, and re-export; any
      #       lossy transcoding can be done downstream on a copy without degrading
      #       the original capture.
      # Voice Memos is Apple-only; no Windows/NixOS equivalent exists.
      # Source: https://support.apple.com/en-us/guide/voice-memos/welcome/mac
      "com.apple.VoiceMemos" = {
        RCVoiceMemosAudioQualityKey = 1;
      };

      # Window Manager: enable click-to-show-desktop, hide Stage Manager widgets
      # for lower visual noise, and keep window tiling enabled (macOS 15+).
      # Source: https://support.apple.com/en-us/guide/mac-help/stage-manager-mchl534ba392/mac
      "com.apple.WindowManager" = {
        EnableStandardClickToShowDesktop = true;
        StandardHideWidgets = true; # hide Stage Manager widget strip to reduce persistent chrome
        WindowTilingEnabled = true; # enable drag-to-edge window tiling (Sequoia)
      };

      # Siri / dictation backend preferences.
      # Source: https://support.apple.com/en-us/guide/mac-help/type-to-siri-on-mac-mh40725/mac
      "com.apple.assistant.support" = {
        "Assistant Enabled" = true;
        "Auto Punctuation Enabled" = true; # insert punctuation during dictation
        "Dictation Enabled" = true;
        "Siri Data Sharing Opt-In Status" = 1; # opt in to Siri improvement program
      };

      # macOS tips and suggestions: disable persistent notifications.
      # These interrupt focus and offer limited value for power-user workflows.
      # Source: https://support.apple.com/en-us/guide/mac-help/change-notifications-settings-on-mac-mh40583/mac
      "com.apple.tips" = {
        LastSeenVersionForAutoStartTip = 99999; # mark all tips as already seen
        ShowTipOfTheDay = false; # disable daily tip notification entirely
      };

      # Raycast: hide menu bar icon to reduce persistent chrome.
      # This complements the Spotlight menu bar hide for a cleaner status bar.
      # Note: Raycast must be hidden via Raycast Settings → General → Menu Bar Icon
      # as well, but this plist setting provides additional enforcement.
      # ˜This key may not exist in all Raycast versions; inclusion is defensive.~

      # App Store: enable automatic app updates.
      # Source: https://support.apple.com/en-us/guide/app-store/fetch-updates-fir9b01adda3/mac
      "com.apple.commerce" = {
        AutoUpdate = true;
      };

      # Control Centre: show battery percentage; tighten status-item spacing.
      # Source: https://support.apple.com/en-us/guide/mac-help/mchlad96d366/mac
      "com.apple.controlcenter" = {
        BatteryShowPercentage = true;
        NSStatusItemSelectionPadding = 6; # pixels of padding around selected item
        NSStatusItemSpacing = 6; # pixels between status items
      };

      # Prevent macOS from writing .DS_Store files on network and removable
      # volumes. macOS does not provide an equivalent supported toggle for local
      # APFS/HFS+ folders.
      # Source: https://support.apple.com/en-us/HT208209
      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };

      # Dock: disable Stage Manager / Widget corner zones (value 0 = no-op).
      # Source: https://support.apple.com/en-us/guide/mac-help/mchlp1119/mac
      "com.apple.dock" = {
        wdev-bl = 0;
        wdev-br = 0;
        wdev-tl = 0;
        wdev-tr = 0;
      };

      # Finder: desktop visibility, iCloud Drive folder pinning, and UI prefs.
      # WHY: in CustomUserPreferences: Finder reads these from the user domain
      # (~/.Library/Preferences/com.apple.finder.plist), not system domain.
      # These settings MUST be written via CustomUserPreferences to take effect.
      # Source: https://support.apple.com/en-us/guide/mac-help/finder-settings-mchla834/mac
      "com.apple.finder" = {
        # Desktop visibility: show mounted drives, external drives, servers, removable media.
        # These are intentionally kept in user domain (not system.defaults.finder) because
        # Finder only respects them when written to per-user preferences.
        CreateDesktop = true; # allow files/icons on the Desktop
        ShowExternalHardDrivesOnDesktop = true; # show external drives on Desktop
        ShowHardDrivesOnDesktop = true; # show internal hard drives on Desktop
        ShowMountedServersOnDesktop = true; # show mounted NFS/SMB shares on Desktop
        ShowRemovableMediaOnDesktop = true; # show USB drives and optical media on Desktop

        # Keep Desktop and Documents in iCloud Drive. These knobs are not
        # currently part of nix-darwin's typed `system.defaults.finder` set,
        # so they are expressed as custom domain values.
        FXICloudDriveDesktop = true;
        FXICloudDriveDocuments = true;

        # Keep the empty-trash confirmation prompt enabled. This key is not a
        # typed nix-darwin finder option, so we set it as a custom default.
        WarnOnEmptyTrash = true;

        # Desktop icon layout: keep deterministic icon geometry and snap every
        # icon to Finder's grid so drag/reorder actions remain tidy by default.
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

      # Menu bar clock: full date + time with seconds.
      # Source: https://support.apple.com/en-us/guide/mac-help/mchlp1124/mac
      "com.apple.menuextra.clock" = {
        DateFormat = "EEE y-MM-dd HH:mm:ss";
        ShowDate = 1;
        ShowDayOfWeek = true;
        ShowSeconds = true;
      };

      # Screensaver: require password immediately after the screensaver engages.
      # Source: https://support.apple.com/en-us/guide/mac-help/set-your-mac-to-require-a-password-mchlp2270/mac
      "com.apple.screensaver" = {
        askForPassword = true;
        askForPasswordDelay = 0; # seconds before password is required (0 = immediately)
      };

      # Dictation shortcut: double-press Right Command key (value 2).
      # Source: https://support.apple.com/en-us/guide/mac-help/use-dictation-mh40584/mac
      "com.apple.speech.recognition.AppleSpeechRecognition.prefs" = {
        DictationShortcut = 2;
      };

      # Mission Control: span desktops across multiple displays so every monitor
      # follows the same active Space when switching desktops.
      # Source: https://support.apple.com/en-us/guide/mac-help/work-in-multiple-spaces-mh14112/mac
      "com.apple.spaces" = {
        "spans-displays" = true;
      };

      # Raycast: comprehensive declarative configuration of all plist-settable options.
      # WHY: Most Raycast settings live in SQLite database (Raycast internals), not
      # plist. We configure only documented/stable plist keys here. Advanced settings
      # like Pop to Root timeout, Escape behavior, Navigation bindings, and Root Search
      # Sensitivity require manual configuration in Raycast UI → Settings → Advanced.
      # Source: https://manual.raycast.com
      "com.raycast.macos" = {
        # --- Startup & Window Behavior ---
        LaunchAtLogin = true; # Launch Raycast at login
        Appearance = "system"; # Auto Dark/Light based on time of day
        WindowMode = "default"; # Use default window (not compact)
        ShowMenuBarIcon = false; # Hide Raycast icon from menu bar
        ShowFavoritesInCompactMode = true; # Show favorites in compact mode

        # --- Appearance & Text ---
        # Text size: default/medium (Raycast's baseline; plist key unclear, may be UI-only)
        # Menu Bar: explicitly disabled above to reduce persistent chrome

        # --- Network & Security ---
        UseSystemNetworkSettings = true; # Web proxy from macOS System Settings
        CertificatesProvider = "Keychain"; # Use Keychain for certificate validation

        # --- Extensions & Providers ---
        FaviconProvider = "Raycast"; # Raycast's built-in favicon resolver

        # --- Developer Tools ---
        DeveloperMode = true; # Enable development mode
        AutoReloadOnSave = true; # Auto-reload on script save
        # Note: Additional dev settings (Use Node production, logging, disable pop to root)
        # are database-only; configure manually in Settings → Advanced → Developer Tools

        # --- Database-Only Settings (Manual Configuration Required) ---
        # The following settings are NOT plist-configurable; configure via Raycast UI:
        #   • Clipboard History hotkey: Open Raycast Settings → Shortcuts → Search "Clipboard"
        #     → Record Hotkey → Press ⌥⌘C (manually configured, stored in Raycast database)
        #   • Raycast Hotkey: Set to cmd+space manually (Raycast Settings → Hotkey)
        #   • Show Raycast on screen: Screen containing mouse (Settings → General)
        #   • Pop to Root Search: After 180 seconds (Settings → Advanced)
        #   • Escape Key Behavior: Close window and pop to root (Settings → Advanced)
        #   • Auto-switch Input Source: Disabled (Settings → Advanced)
        #   • Navigation Bindings: Vim Style (Settings → Advanced)
        #   • Page Navigation Keys: Square Brackets (Settings → Advanced)
        #   • Root Search Sensitivity: High (Settings → Advanced)
        #   • Hyper Key: Disabled (Settings → Advanced)
        #   • Emoji Skin Tone: Light/Yellow (Settings → Advanced)
        #   • Window Capture: Record Hotkey, Copy to clipboard ✓ (Settings → Advanced)
        #   • Custom Wallpaper: Optional (Settings → Advanced)
      };
      # Terminal: focus follows mouse pointer (hover to focus without clicking).
      # Source: https://support.apple.com/en-us/guide/terminal/welcome/mac
      "com.apple.terminal" = {
        FocusFollowsMouse = "YES";
      };

      # Universal Control: automatically connect to nearby Mac/iPad.
      # Source: https://support.apple.com/en-us/guide/mac-help/use-universal-control-mchl89c97b09/mac
      "com.apple.universalcontrol" = {
        autoConnect = true;
      };

      # Archive Vault and Password/Passkey Autofill settings.
      # Handles iCloud Archive Vault, Safari password autofill, and verification
      # code management as shown in System Settings > Passwords.
      # Note: com.apple.iCloud.fmip.preferences is an internal Apple domain with
      # no public developer documentation; keys are empirically observed.
      "com.apple.iCloud.fmip.preferences" = {
        # Archive Vault: encrypt Mac content with password-protected storage.
        # This enables the Archive Vault feature in iCloud+ settings.
        ArchiveVaultEnabled = 1;
      };

      # Password and passkey autofill settings for Safari and login fields.
      # These control the "Settings" app behavior for autofill across the system.
      # Source: https://developer.apple.com/documentation/passkit
      "com.apple.PassKit.policy" = {
        AutoFillPasskeysAndPasswords = 1; # enable autofill for passwords/passkeys
        AutoFillPasskeysAndPasswordsSource = "com.apple.Passwords"; # use macOS Passwords app
        SetupVerificationCodesEnabled = 1; # enable verification code setup
        DeleteVerificationCodesAfterUse = 0; # do NOT auto-delete codes after use
      };

      # BetterDisplay: launch at login, show resolutions as a flat list, use
      # maximum native resolution by default, configure update settings, enable
      # crash reporting, disable professional features (licensing), and set delay
      # values for display transitions.
      #
      # Note: preferences domain is pro.betterdisplay.BetterDisplay (not
      # com.betterdisplay). Source:
      # https://github.com/waydabber/BetterDisplay/wiki
      # Screenshot configurations:
      #   - LaunchAtLogin: true (app auto-starts at login)
      #   - hideMenuIcon: true (hide app icon in BetterDisplay menu UI)
      #   - showInMenuBar: false (deprecated key, kept for cross-release compat)
      #   - sendCrashReports: true (auto-send crash logs to developers)
      #   - enableProfessionalFeatures: false (disable pro/licensing management)
      #   - SUEnableAutomaticChecks: false (disable automatic update checking)
      #   - SUAutomaticallyUpdate: false (disable auto-download, manual updates only)
      #   - SUEnablePrerelease: false (disable early access to prerelease builds)
      #   - setDelay: 0.2s (display setting transition time)
      #   - wakeDelay: 1.5s (wake-from-sleep transition time)
      "pro.betterdisplay.BetterDisplay" = {
        LaunchAtLogin = true;
        hideMenuIcon = true;
        ShowResolutionsAsList = true;
        UseMaximumResolution = true;
        sendCrashReports = true;
        showInMenuBar = false;
        enableProfessionalFeatures = false;
        setDelay = 0.2;
        wakeDelay = 1.5;
        SUEnableAutomaticChecks = false;
        SUAutomaticallyUpdate = false;
        SUEnablePrerelease = false;
      };

      # AltTab: declare switcher behavior explicitly (including values that
      # match upstream defaults) so rebuilds keep runtime behavior stable.
      #
      # Preference keys and enum index ordering are defined by upstream here:
      # - https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/src/preferences/Preferences.swift
      # - https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/src/preferences/MacroPreferences.swift
      #
      # Note: Shortcut values are persisted by AltTab as encoded shortcut
      # payloads after app-side migration; this block keeps key-equivalent
      # strings explicit for declarative intent and convergence.
      "com.lwouis.alt-tab-macos" = {
        # --- Requested appearance ---
        appearanceStyle = "2"; # titles
        appearanceSize = "3"; # auto
        appearanceTheme = "2"; # system
        shortcutStyle = "0"; # focus on release
        previewFocusedWindow = "false";

        # --- Requested multi-display behavior ---
        showOnScreen = "1"; # screen including mouse

        # --- Requested controls ---
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

        # --- Requested other settings ---
        cursorFollowFocus = "0"; # never
        trackpadHapticFeedbackEnabled = "true";

        # --- Requested general settings ---
        startAtLogin = "true";
        menubarIconShown = "false";
        captureWindowsInBackground = "true";
        language = "0"; # system default
        updatePolicy = "0"; # do not check periodically
        crashPolicy = "2"; # always send crash reports
      };

      # LinearMouse: configure menu bar visibility, battery indicator,
      # dock visibility, and launch-at-login behavior.
      #
      # Domain source and migration context:
      # https://github.com/linearmouse/linearmouse/wiki
      # Runtime writes in src/modules/macos.nix target both
      # org.linearmouse.LinearMouse and com.lujjjh.LinearMouse because both
      # domains can appear on migrated installs.
      # Screenshot configurations:
      #   - showInMenuBar: false (menu bar icon hidden declaratively via
      #     CustomUserPreferences)
      #   - showBattery: "always" (always display battery in menu bar when visible)
      #   - showInDock: true (app icon visible in Dock)
      #   - launchAtLogin: true (app auto-starts at login)
      #   - Also: disable automatic update checks (Sparkle preferences)
      "com.lujjjh.LinearMouse" = {
        showInMenuBar = false;
        showBattery = "always";
        showInDock = true;
        launchAtLogin = true;
        SUEnableAutomaticChecks = false;
        SUAutomaticallyUpdate = false;
      };
      "org.linearmouse.LinearMouse" = {
        showInMenuBar = false;
        showBattery = "always";
        showInDock = true;
        launchAtLogin = true;
        SUEnableAutomaticChecks = false;
        SUAutomaticallyUpdate = false;
      };

      # iTerm2 terminal emulator app-level preferences (not per-profile settings).
      #
      # Source: https://iterm2.com/documentation.html
      "com.googlecode.iterm2" = {
        # Set the default profile GUID to the Dynamic Profile defined in
        # check-suppress:config-method: method 1 (writable symlink) -- src/users/default/iterm2/DynamicProfiles/default-profile.json via iterm2.nix
        # This key (KEY_DEFAULT_GUID) tells iTerm2 which profile to use for
        # new windows/tabs when no other profile is explicitly selected.
        # Source: ITAddressBookMgr.h
        "Default Bookmark Guid" = "9B6E253F-0528-4F8A-A025-4FD279C73DB1";
        # Allow clipboard access from terminal applications.
        "AllowClipboardAccess" = true;
        # Bootstrap daemon: supports shell integration without requiring a full
        # app launch.
        "BootstrapDaemon" = true;
        # Enable "Open in iTerm" Finder right-click context menu.
        "EnableFindersService" = true;
        # Pre-answer the first-launch "may we show you tips?" permission prompt
        # so iTerm2 skips that dialog on a fresh provision and goes straight to
        # showing tips.  Simulates the state where the user already answered yes.
        "NoSyncPermissionToShowTip" = true;
        "NoSyncTipOfTheDay" = true;
        # Blocks other processes from reading keystrokes.
        "Secure Input" = true;
        # Disable in-app update checks; updates are managed declaratively.
        "SUCheckAtStartup" = false;
        "SUEnableAutomaticChecks" = false;
        # Suppress the "Warn about short-lived sessions" dialog for each profile.
        # The NeverWarnAboutShortLivedSessions_<GUID> key silences the iTermWarning
        # that fires when a session ends within shortLivedSessionDuration (default 3s).
        # Source: PTYSession.m _maybeWarnAboutShortLivedSessions
        "NeverWarnAboutShortLivedSessions_743F1344-118A-4E38-8CB0-D7319D34EF8C" = true;
        "NeverWarnAboutShortLivedSessions_9B6E253F-0528-4F8A-A025-4FD279C73DB1" = true;
        # Suppress the secure-keyboard-entry warning when opening a command.
        "WarnAboutSecureKeyboardInputWithOpenCommand" = false;
      };

      # Amphetamine: declaratively enable the Power Protect install toggle.
      # WHY: partial declarative only: upstream requires users to place the
      # helper script and sudoers fragment manually due platform restrictions;
      # this key activates that feature path once those files exist.
      # Source (upstream maintainer docs):
      # https://raw.githubusercontent.com/x74353/Amphetamine/master/README.md
      # Parity note: this feature is macOS-only; there is no equivalent
      # Power Protect surface on NixOS/Windows in this repository.
      "com.if.Amphetamine" = {
        "Enable Power Protect Install" = true;
      };

      # VS Code (stable and Insiders): disable ApplePressAndHold so held
      # keys repeat. Required for vim motions (h/j/k/l) via vscode-neovim.
      "com.microsoft.VSCode" = {
        ApplePressAndHoldEnabled = false;
      };
      "com.microsoft.VSCodeInsiders" = {
        ApplePressAndHoldEnabled = false;
      };
    };

    # -------------------------------------------------------------------------
    # Dock settings
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # Finder settings (user domain via system.defaults.finder; some settings
    # like desktop visibility are defined in CustomUserPreferences instead)
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # CustomSystemPreferences — arbitrary system-level defaults not exposed as
    # first-class nix-darwin options.  Written with `sudo defaults write`.
    # -------------------------------------------------------------------------
    CustomSystemPreferences = {
      # Enable automatic crash-report and diagnostic submission to Apple.
      # Source: https://support.apple.com/en-us/guide/deployment/privacy-management-dep4db1d2fa4/web
      "com.apple.SubmitDiagInfo".SubmitDiagInfo = true;

      # Ambient-light-sensor threshold that drives keyboard backlight brightness.
      # 25 maps to roughly half brightness in subdued lighting conditions.
      # Note: com.apple.iokit.AmbientLightSensor is a kernel IOKit domain with
      # no public Apple developer reference; values are empirically calibrated.
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
      disable-shadow = true; # omit window drop-shadow from screenshots
      location = "~/Desktop"; # default save location
      # WHY: target is explicitly set: keep clipboard-first capture behavior as the
      # default while still retaining a deterministic file-save location for
      # workflows that explicitly switch target back to file.
      target = "clipboard"; # default capture destination
      type = "png"; # default file format
    };

    # -------------------------------------------------------------------------
    # Trackpad settings (system-level; fine-grained per-app settings are in
    # CustomUserPreferences.com.apple.AppleMultitouchTrackpad above)
    # -------------------------------------------------------------------------
    trackpad = {
      Clicking = true; # tap to click
      TrackpadThreeFingerDrag = true; # drag windows with three fingers
    };
  };
}
