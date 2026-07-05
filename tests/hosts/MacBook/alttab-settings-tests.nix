# tests/hosts/MacBook/alttab-settings-tests.nix — Verify explicit AltTab settings wiring on macOS.
#
# This suite ensures all requested AltTab preferences remain declared in
# defaults.nix so host rebuilds converge the same behavior every run.
# AltTab is macOS-only; NixOS and Windows have no equivalent preference domain.

let
  lib = import <nixpkgs/lib>;
  defaultsText = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
in
assert lib.hasInfix ''"com.lwouis.alt-tab-macos"'' defaultsText;

# Appearance
assert lib.hasInfix ''appearanceStyle = "2";'' defaultsText;
assert lib.hasInfix ''appearanceSize = "3";'' defaultsText;
assert lib.hasInfix ''appearanceTheme = "2";'' defaultsText;
assert lib.hasInfix ''shortcutStyle = "0";'' defaultsText;
assert lib.hasInfix ''previewFocusedWindow = "false";'' defaultsText;

# Multiple screens
assert lib.hasInfix ''showOnScreen = "1";'' defaultsText;

# Controls: shortcut 1
assert lib.hasInfix ''shortcutCount = "2";'' defaultsText;
assert lib.hasInfix ''holdShortcut = "⌥";'' defaultsText;
assert lib.hasInfix ''nextWindowShortcut = "→";'' defaultsText;
assert lib.hasInfix ''appsToShow = "0";'' defaultsText;
assert lib.hasInfix ''spacesToShow = "0";'' defaultsText;
assert lib.hasInfix ''screensToShow = "0";'' defaultsText;
assert lib.hasInfix ''showMinimizedWindows = "0";'' defaultsText;
assert lib.hasInfix ''showHiddenWindows = "0";'' defaultsText;
assert lib.hasInfix ''showFullscreenWindows = "0";'' defaultsText;
assert lib.hasInfix ''showWindowlessApps = "2";'' defaultsText;
assert lib.hasInfix ''windowOrder = "0";'' defaultsText;

# Controls: shortcut 2
assert lib.hasInfix ''holdShortcut2 = "⌥";'' defaultsText;
assert lib.hasInfix ''nextWindowShortcut2 = "`";'' defaultsText;
assert lib.hasInfix ''appsToShow2 = "1";'' defaultsText;
assert lib.hasInfix ''spacesToShow2 = "0";'' defaultsText;
assert lib.hasInfix ''screensToShow2 = "0";'' defaultsText;
assert lib.hasInfix ''showMinimizedWindows2 = "0";'' defaultsText;
assert lib.hasInfix ''showHiddenWindows2 = "0";'' defaultsText;
assert lib.hasInfix ''showFullscreenWindows2 = "0";'' defaultsText;
assert lib.hasInfix ''showWindowlessApps2 = "2";'' defaultsText;
assert lib.hasInfix ''windowOrder2 = "0";'' defaultsText;
assert lib.hasInfix ''shortcutStyle2 = "0";'' defaultsText;
assert lib.hasInfix ''previewFocusedWindow2 = "false";'' defaultsText;

# Controls: gesture profile disabled
assert lib.hasInfix ''nextWindowGesture = "0";'' defaultsText;
assert lib.hasInfix ''appsToShow10 = "0";'' defaultsText;
assert lib.hasInfix ''spacesToShow10 = "0";'' defaultsText;
assert lib.hasInfix ''screensToShow10 = "0";'' defaultsText;
assert lib.hasInfix ''showMinimizedWindows10 = "0";'' defaultsText;
assert lib.hasInfix ''showHiddenWindows10 = "0";'' defaultsText;
assert lib.hasInfix ''showFullscreenWindows10 = "0";'' defaultsText;
assert lib.hasInfix ''showWindowlessApps10 = "2";'' defaultsText;
assert lib.hasInfix ''windowOrder10 = "0";'' defaultsText;
assert lib.hasInfix ''shortcutStyle10 = "0";'' defaultsText;
assert lib.hasInfix ''previewFocusedWindow10 = "false";'' defaultsText;

# Other controls
assert lib.hasInfix ''arrowKeysEnabled = "true";'' defaultsText;
assert lib.hasInfix ''vimKeysEnabled = "false";'' defaultsText;
assert lib.hasInfix ''mouseHoverEnabled = "false";'' defaultsText;

# Other
assert lib.hasInfix ''cursorFollowFocus = "0";'' defaultsText;
assert lib.hasInfix ''trackpadHapticFeedbackEnabled = "true";'' defaultsText;

# General
assert lib.hasInfix ''startAtLogin = "true";'' defaultsText;
assert lib.hasInfix ''menubarIconShown = "false";'' defaultsText;
assert lib.hasInfix ''captureWindowsInBackground = "true";'' defaultsText;
assert lib.hasInfix ''language = "0";'' defaultsText;
assert lib.hasInfix ''updatePolicy = "0";'' defaultsText;
assert lib.hasInfix ''crashPolicy = "2";'' defaultsText;

true
