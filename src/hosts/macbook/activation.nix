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
  #   display  = 1       — display sleeps after 1 minute to save power
  #   harddisk = "never" — disk sleep disabled            (was: pmset -a disksleep 0)
  #   restartAfterPowerFailure is intentionally omitted because this machine
  #   model/firmware does not support it; setting it at all causes activation
  #   failure on this hardware.
  # ---------------------------------------------------------------------------
  power.sleep.computer = "never";
  power.sleep.display = 1;
  power.sleep.harddisk = "never";
  # power.restartAfterPowerFailure = true;  # Keep the comment and keep it disabled.

  # ---------------------------------------------------------------------------
  # configureBatteryPolicy
  # Fine-grained pmset policy not fully covered by nix-darwin's power module:
  #   -a: shared behavior for all power sources (wake/network/background)
  #   -c: charger profile (max performance, no forced sleep)
  #   -b: battery profile (balanced mobile behavior)
  # sleep/displaysleep/disksleep continue to be handled declaratively above via
  # power.sleep.*. `autorestart` is intentionally unmanaged because this host
  # cannot safely apply restart-after-power-failure.
  # The -x flag check is present because pmset might be absent in certain VM
  # or CI environments where this config could theoretically be evaluated.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureBatteryPolicy.text = ''
    if [ -x /usr/bin/pmset ]; then
      /usr/bin/pmset -a womp 1 powernap 1 lidwake 1
      /usr/bin/pmset -c highpowermode 1 disablesleep 1
      /usr/bin/pmset -b highpowermode 0 disablesleep 0 lowpowermode 0
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureChargeLimit
  # Uses bclm (Battery Charge Level Max) to cap charge at 80 % by default,
  # reducing long-term cell stress for a mostly-docked development machine.
  # `persist` ensures the SMC setting survives reboot.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureChargeLimit.text = ''
    if [ -x /opt/homebrew/bin/bclm ]; then
      /opt/homebrew/bin/bclm write 80 || echo "[ERROR] bclm write failed" >&2
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
