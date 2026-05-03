# macbook/activation.nix — nix-darwin system.activationScripts for the MacBook.
#
# All scripts run as root during `darwin-rebuild switch`.  Because
# system.activationScripts is a nix-darwin-only option they are guaranteed to
# execute on macOS; no OS check inside the shell body is needed.
{ ... }:
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
}
