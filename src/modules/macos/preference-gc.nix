# modules/macos/preference-gc.nix — Managed macOS preference domain GC.
#
# Provides the domain list and drift-reset script for purging stale user
# preference state before declarative re-assertion.
{ pkgs, ... }:
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
  # Source for preference-domain write semantics: defaults(1).
  # https://www.manpagez.com/man/1/defaults/
  resetUserPreferenceDomains = [
    "NSGlobalDomain"
    "com.apple.ActivityMonitor"
    "com.apple.AdLib"
    "com.apple.AppleMultitouchTrackpad"
    "com.apple.BezelServices"
    "com.apple.CloudDocs"
    "com.apple.HIToolbox"
    "com.apple.LaunchServices"
    "com.apple.Photos"
    "com.apple.Safari"
    "com.apple.Siri"
    "com.apple.SoftwareUpdate"
    "com.apple.Spotlight"
    "com.apple.SubmitDiagInfo"
    "com.apple.TextEdit"
    "com.apple.TextInput.Kybd"
    "com.apple.TextInputMenu"
    "com.apple.VoiceMemos"
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
    "com.apple.speech.recognition.AppleSpeechRecognition.prefs"
    "com.apple.spaces"
    "com.apple.spotlight"
    "com.apple.symbolichotkeys"
    "com.apple.terminal"
    "com.apple.universalaccess"
    "com.apple.universalcontrol"
    "pro.betterdisplay.BetterDisplay"
    "com.googlecode.iterm2"
    "com.raycast.macos"
  ];
in
{
  inherit resetUserPreferenceDomains;

  # Manual drift-reset helper for managed macOS preference domains.
  # This is intentionally a user-invoked command instead of an automatic
  # activation phase so destructive purge operations cannot race with
  # writeBoundary defaults application.
  managedPreferencesGcScript = pkgs.writeShellScriptBin "gc-managed-user-preferences" ''
    NIX_STORE_BIN="${pkgs.nix}/bin/nix-store"
    MANAGED_PREF_DOMAINS="${builtins.concatStringsSep " " resetUserPreferenceDomains}"
    ${builtins.readFile ../../scripts/hosts/MacBook/macos-gc-preferences.sh}
    ${builtins.readFile ../../scripts/hosts/MacBook/macos-refresh-cfprefsd.sh}

    echo "Managed preference domains purged. Run your apply flow to re-assert declarative defaults."
  '';
}
