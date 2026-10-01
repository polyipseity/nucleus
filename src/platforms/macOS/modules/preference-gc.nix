# platforms/macOS/modules/preference-gc.nix - Managed macOS preference domain GC.
#
# Domain list and drift-reset script, so a stale manual override in
# ~/Library/Preferences cannot survive the declarative write pass.
{ ... }:
let
  # Resets run before each Home Manager write pass. A new system.defaults option,
  # CustomUserPreferences payload, or activation defaults hook has to add its
  # domain here too. Keep the list alphabetically sorted.
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
    "com.apple.PassKit.policy"
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
    "com.googlecode.iterm2"
    "com.if.Amphetamine"
    "com.knollsoft.Rectangle"
    "com.lwouis.alt-tab-macos"
    "com.raycast.macos"
    "org.linearmouse.LinearMouse"
    "pro.betterdisplay.BetterDisplay"
  ];
in
{
  inherit resetUserPreferenceDomains;
}
