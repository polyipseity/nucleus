# macbook/activation.nix — nix-darwin system.activationScripts for the MacBook.
#
# All scripts run as root during `darwin-rebuild switch`.  Because
# system.activationScripts is a nix-darwin-only option they are guaranteed to
# execute on macOS; no OS check inside the shell body is needed.
{ ... }:
let
  # When true, Arduino IDE 1.8 is downloaded and installed to /Applications.
  # Set to false to have the activation script remove it instead.
  enableArduinoIDE = true;
in
{
  # ---------------------------------------------------------------------------
  # Declarative power-management settings handled by nix-darwin's power module.
  # These translate to systemsetup / pmset calls at activation time.
  #   computer = "never" — idle sleep disabled            (was: pmset -a sleep 0)
  #   display  = "never" — displays never sleep           (was: pmset -a displaysleep 0)
  #   harddisk = "never" — disk sleep disabled            (was: pmset -a disksleep 0)
  #   restartAfterPowerFailure — recover from power loss  (was: pmset -c autorestart 1)
  # ---------------------------------------------------------------------------
  power.sleep.computer = "never";
  power.sleep.display = "never";
  power.sleep.harddisk = "never";
  power.restartAfterPowerFailure = true;

  # ---------------------------------------------------------------------------
  # configureBatteryPolicy
  # Imperative pmset settings that have no nix-darwin declarative equivalent:
  #   disablesleep 1   — prevent the system from ever sleeping
  #   lidwake 0        — do not wake on lid open (headless remote use)
  #   womp 1           — wake on network access (Wake on LAN)
  #   powernap 1       — allow background fetches during Power Nap
  #   highpowermode 1  — use maximum CPU/GPU performance on AC
  #   lowpowermode 0   — disable Low Power Mode explicitly
  # sleep / displaysleep / disksleep / autorestart are handled declaratively
  # above via the power.sleep.* and power.restartAfterPowerFailure options.
  # The -x flag check is present because pmset might be absent in certain VM
  # or CI environments where this config could theoretically be evaluated.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureBatteryPolicy.text = ''
    if [ -x /usr/bin/pmset ]; then
      /usr/bin/pmset -a disablesleep 1 lidwake 0
      /usr/bin/pmset -a womp 1 powernap 1
      /usr/bin/pmset -c highpowermode 1 lowpowermode 0
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureChargeLimit
  # Uses bclm (Battery Charge Level Max) to cap the battery charge at 100 %
  # and persists the setting across reboots.  Capping at 100 % is equivalent
  # to "no limit" but the persist call ensures the SMC does not reset the value.
  # A future change to e.g. 80 % would just update the `write` argument.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureChargeLimit.text = ''
    if [ -x /opt/homebrew/bin/bclm ]; then
      /opt/homebrew/bin/bclm write 100 || echo "[ERROR] bclm write failed" >&2
      /opt/homebrew/bin/bclm persist || echo "[ERROR] bclm persist failed" >&2
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureMonitorColorProfile
  # Clears the ColorSync device-profile cache so that newly connected monitors
  # re-trigger profile detection and pick up the correct ICC profile.
  # `|| true` because the key may not exist on a fresh installation.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureMonitorColorProfile.text = ''
    /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache || true
  '';

  # ---------------------------------------------------------------------------
  # configurePostActivation
  # Runs final one-time setup tasks that require the rest of the system to be
  # fully activated first:
  #
  #   Rosetta 2: installs the x86_64 translation layer if oahd (the Rosetta
  #   daemon) is not already running.  Required for x86_64-only binaries.
  #
  #   Arduino IDE: conditionally installs or removes Arduino IDE 1.8.19.
  #   Controlled by the `enableArduinoIDE` Nix boolean above; the branch is
  #   resolved at eval time so only the relevant shell block is embedded.
  # ---------------------------------------------------------------------------
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
