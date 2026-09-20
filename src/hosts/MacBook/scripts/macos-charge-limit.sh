#!/usr/bin/env bash
# Keep charge capped at 80 % to reduce long-term battery wear on a mostly
# docked development machine.
#
# The cap is enforced by the `battery` CLI, which writes the firmware-level SMC
# charging gate and installs a headless LaunchAgent (com.battery.app) so the cap
# holds with no tray app open.  The gate lives in firmware, so it also survives
# sleep and shutdown.
#
# WHY: the macOS-native Charge Limit (macOS 26.4+) is deliberately not converged
#   here.  It has no `pmset` key, no configuration-profile payload, and no
#   supported CLI — Apple exposes it only to the Settings UI and to a Shortcuts
#   action, and Shortcuts workflows cannot be authored from the command line.
#   Automating it would therefore mean requiring a hand-built shortcut, so the
#   native limit stays a one-time manual setting (see MANUAL.md).  It can only
#   lower the ceiling (80–100 %), so with the gate below at 80 % the effective
#   cap is 80 % whether or not it is set.
#
# Manual conflict proof (needs root; documented rather than executed during
# activation because SMC reads require elevated I/O access and are diagnostic
# only):
#   sudo /usr/local/co.palokaj.battery/smc -k CHWA -r
#   → 01 means the firmware 80 % charge limit is engaged.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

charge_limit_percent=80

battery_app="/Applications/battery.app"
battery_cli=""
for candidate in /usr/local/bin/battery /usr/local/co.palokaj.battery/battery; do
  if [ -x "$candidate" ]; then
    battery_cli="$candidate"
    break
  fi
done

# The helper keeps its state in the console user's HOME, so convergence is
# console-user scoped.
# WHY: a headless/SSH activation has no session to converge, so warn instead of
#   failing the apply — the machine is not misconfigured, it is unattended.
if ! _nucleus_resolve_console_user; then
  warn -l power "no console user session; skipped ${charge_limit_percent}% charge-limit convergence."
  exit 0
fi

if [ -n "$battery_cli" ]; then
  # -H sets HOME to the target user's home directory.  Without it, sudo
  # inherits HOME=/var/root from the root activation context, causing
  # battery to write its state files to /var/root/.battery/ which the
  # console user cannot write to.
  #
  # Redirect stdin/stdout/stderr to /dev/null: battery maintain forks a
  # long-running background daemon via `nohup ... &` that inherits open
  # file descriptors.  Without this redirect, the daemon holds the
  # activation pipeline's pipe write-end open indefinitely, causing any
  # `./scripts/bootstrap.sh apply ... | <cmd>` invocation to hang until
  # the daemon exits (which is never during normal operation).  The exit
  # code is still checked below so real failures are not silenced;
  # battery's own log file (~/.battery/battery.log) retains full
  # diagnostic output for post-failure inspection.
  if ! /usr/bin/sudo -H -u "$_nucleus_console_user" "$battery_cli" maintain "$charge_limit_percent" </dev/null >/dev/null 2>&1; then
    die -l power "battery maintain ${charge_limit_percent} failed for user '$_nucleus_console_user'."
  fi
elif [ -d "$battery_app" ]; then
  warn -l power "battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command."
else
  warn -l power "no supported battery charge-limit tool found (expected /usr/local/bin/battery)."
fi
