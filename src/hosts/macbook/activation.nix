{ ... }:
let
  enableArduinoIDE = true;
in
{
  system.activationScripts.configureBatteryPolicy.text = ''
    if [ -x /usr/bin/pmset ]; then
      /usr/bin/pmset -a disablesleep 1 lidwake 0 displaysleep 0 sleep 0 disksleep 0
      /usr/bin/pmset -a womp 1 powernap 1
      /usr/bin/pmset -c autorestart 1 highpowermode 1 lowpowermode 0
    fi
  '';

  system.activationScripts.configureChargeLimit.text = ''
    if [ -x /opt/homebrew/bin/bclm ]; then
      /opt/homebrew/bin/bclm write 100 || echo "[ERROR] bclm write failed" >&2
      /opt/homebrew/bin/bclm persist || echo "[ERROR] bclm persist failed" >&2
    fi
  '';

  system.activationScripts.configureDiagnostics.text = ''
    /usr/bin/defaults write /Library/Preferences/com.apple.SubmitDiagInfo SubmitDiagInfo -bool true
  '';

  system.activationScripts.configureKeyboardBrightness.text = ''
    /usr/bin/defaults write /Library/Preferences/com.apple.iokit.AmbientLightSensor "Keyboard Backlight Error Condition" -int 25 || true
  '';

  system.activationScripts.configureLockScreenMessage.text = ''
    /usr/bin/defaults write /Library/Preferences/com.apple.loginwindow LoginwindowText "✨"
  '';

  system.activationScripts.configureMonitorColorProfile.text = ''
    /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache || true
  '';

  system.activationScripts.configurePostActivation.text = ''
    if ! /usr/bin/pgrep -q oahd; then
      /usr/sbin/softwareupdate --install-rosetta --agree-to-license || true
    fi

    ARDUINO_APP="/Applications/Arduino.app"
    ${if enableArduinoIDE then ''
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
    '' else ''
    [ -d "$ARDUINO_APP" ] && /bin/rm -rf "$ARDUINO_APP"
    ''}
  '';
}
