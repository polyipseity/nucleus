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
  # Enforce pmset values directly for AC and battery because newer macOS
  # releases can ignore or partially override higher-level power options.
  #
  # Invariant:
  #   - Battery: 1-minute system sleep, 1-minute disk sleep, low-power mode on
  #   - Battery display sleep and wake-on-LAN are intentionally unmanaged:
  #     with low-power mode enabled on this host, macOS keeps forcing
  #     displaysleep=2 and womp=0 after writes.
  #   - AC: 1-minute display sleep, no idle system sleep, no disk sleep,
  #     wake-on-LAN enabled
  #   - Shared: Power Nap and lid wake enabled
  #   - Battery low-power mode on and AC low-power mode off (if supported)
  #
  # This intentionally mirrors the host-specific pmset target profile so that a
  # single activation run can converge drift in both charger and battery modes.
  #
  # The helper emits a clear error when any write fails so a mis-typed key
  # does not silently leave a stale policy in place.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureBatteryPolicy.text = ''
    apply_pmset() {
      if ! /usr/bin/pmset "$@"; then
        echo "nucleus: failed to apply pmset settings: $*" >&2
        return 1
      fi
    }

    pmset_supports() {
      capability="$1"
      /usr/bin/pmset -g cap 2>/dev/null | /usr/bin/grep -Eq "(^|[[:space:]])$capability([[:space:]]|$)"
    }

    if [ -x /usr/bin/pmset ]; then
      apply_pmset -a powernap 1 lidwake 1

      if pmset_supports lowpowermode; then
        apply_pmset -c lowpowermode 0
        apply_pmset -b lowpowermode 1
      fi

      # Apply explicit per-source timers and wake policy after lowpowermode so
      # platform presets cannot silently revert these managed values.
      apply_pmset -c womp 1 displaysleep 1 sleep 0 disksleep 0

      # macOS currently overrides battery displaysleep and womp while
      # lowpowermode is enabled, so only enforce the battery values that remain
      # stable across activation runs.
      apply_pmset -b sleep 1 disksleep 1

      if pmset_supports lessbright; then
        apply_pmset -c lessbright 0
        apply_pmset -b lessbright 1
      fi
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureChargeLimit
  # Keep charge capped at 80 % to reduce long-term battery wear on a mostly
  # docked development machine.
  #
  # On macOS 15+, bclm no longer works due kernel entitlement enforcement.
  # Prefer the maintained `battery` CLI (installed by the `battery` cask) and
  # run it as the active console user so user-scoped launch-agent state stays
  # in that user's home directory.
  #
  # bclm is retained as a fallback only for older macOS versions.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureChargeLimit.text = ''
    console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    macos_major="$(/usr/bin/sw_vers -productVersion 2>/dev/null | /usr/bin/awk -F. '{print $1}')"

    battery_app="/Applications/battery.app"
    battery_cli=""
    for candidate in /usr/local/bin/battery /usr/local/co.palokaj.battery/battery; do
      if [ -x "$candidate" ]; then
        battery_cli="$candidate"
        break
      fi
    done

    if [ -n "$battery_cli" ] && [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
      if ! /usr/bin/sudo -u "$console_user" "$battery_cli" maintain 80; then
        echo "nucleus: battery maintain 80 failed for user '$console_user'." >&2
      fi
    elif [ -x /opt/homebrew/bin/bclm ]; then
      if [ -n "$macos_major" ] && [ "$macos_major" -ge 15 ]; then
        echo "nucleus: bclm is unsupported on macOS >= 15; install and initialize the battery app to enforce 80% charge limit." >&2
      else
        if ! /opt/homebrew/bin/bclm write 80; then
          echo "nucleus: bclm write 80 failed." >&2
        fi
        if ! /opt/homebrew/bin/bclm persist; then
          echo "nucleus: bclm persist failed." >&2
        fi
      fi
    elif [ -d "$battery_app" ]; then
      echo "nucleus: battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command." >&2
    else
      echo "nucleus: no supported battery charge-limit tool found (expected /usr/local/bin/battery or /opt/homebrew/bin/bclm)." >&2
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureMissionControlSpansDisplays
  # Forces Mission Control to span desktops across displays for the currently
  # logged-in console user.  Applying this from system activation ensures the
  # preference is re-asserted after migrations and major macOS updates that
  # sometimes reset com.apple.spaces user defaults.
  #
  # Algorithm:
  #   1. Resolve the active console UID from /dev/console.
  #   2. Skip when no non-root GUI session is present (e.g. headless rebuild).
  #   3. Use launchctl asuser to write the per-user defaults domain as that user.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureMissionControlSpansDisplays.text = ''
    console_uid="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"

    if [ -z "$console_uid" ] || [ "$console_uid" -eq 0 ]; then
      echo "nucleus: no active non-root console user; skipping spans-displays write." >&2
    else
      if ! /bin/launchctl asuser "$console_uid" /usr/bin/defaults write com.apple.spaces spans-displays -bool true; then
        echo "nucleus: failed to enable Mission Control spans-displays for console uid $console_uid." >&2
      fi
    fi
  '';

  # ---------------------------------------------------------------------------
  # configureMonitorColorProfile
  # Clears the ColorSync device-profile cache so that newly connected monitors
  # re-trigger profile detection and pick up the correct ICC profile.
  # A missing key is expected on fresh installs, but we still log that state
  # explicitly instead of suppressing errors.
  # ---------------------------------------------------------------------------
  system.activationScripts.configureMonitorColorProfile.text = ''
    if ! /usr/bin/defaults delete /Library/Preferences/com.apple.ColorSync.DeviceCache; then
      echo "nucleus: ColorSync device cache key absent; skipping delete." >&2
    fi
  '';
}
