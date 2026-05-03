# macbook/manual-installations.nix — imperative installers for manual-only apps.
#
# This module is intentionally limited to software not managed by nixpkgs or
# Homebrew. Keep install/uninstall logic for each manual package here.
{ ... }:
let
  # When true, Arduino IDE 1.8 is downloaded and installed to /Applications.
  # Set to false to have the activation script remove it instead.
  enableArduinoIDE = true;
in
{
  # ---------------------------------------------------------------------------
  # configureRosetta
  # Installs Rosetta 2 once on Apple Silicon hosts if it is not already
  # present. `--agree-to-license` keeps activation non-interactive.
  #
  # Declarative Nix daemon support for x86_64-darwin is configured separately
  # in base.nix via `nix.extraOptions` / `extra-platforms`.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureRosetta.text = ''
    if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto > /dev/null 2>&1; then
      /usr/sbin/softwareupdate --install-rosetta --agree-to-license || true
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureManualApplications
  # Arduino IDE 1.8.19 is distributed as a standalone zip and is managed
  # manually here because it is outside this repo's declarative package sources
  # (nixpkgs/Homebrew policy).
  # ---------------------------------------------------------------------------
  system.activationScripts.configureManualApplications.text = ''
    ARDUINO_APP="/Applications/Arduino.app"
    ARDUINO_URL="https://downloads.arduino.cc/arduino-1.8.19-macosx.zip"

    install_arduino_ide() {
      if [ -d "$ARDUINO_APP" ]; then
        return 0
      fi

      TMP_DIR=$(/usr/bin/mktemp -d)
      if /usr/bin/curl -fsSL -o "$TMP_DIR/arduino.zip" "$ARDUINO_URL"; then
        /usr/bin/unzip -q "$TMP_DIR/arduino.zip" -d "$TMP_DIR"
        if [ -d "$TMP_DIR/Arduino.app" ]; then
          /bin/rm -rf "$ARDUINO_APP"
          /bin/mv "$TMP_DIR/Arduino.app" "$ARDUINO_APP"
        fi
      fi
      /bin/rm -rf "$TMP_DIR"
    }

    uninstall_arduino_ide() {
      [ -d "$ARDUINO_APP" ] && /bin/rm -rf "$ARDUINO_APP"
    }

    ${if enableArduinoIDE then "install_arduino_ide" else "uninstall_arduino_ide"}
  '';
}
