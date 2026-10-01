#!/usr/bin/env bash
# Cap charge at 80 % to reduce battery wear on a mostly docked machine. The
# `battery` CLI writes the firmware SMC charging gate and installs a headless
# LaunchAgent, so the cap holds with no tray app open and survives sleep.
#
# WHY: the macOS-native Charge Limit (macOS 26.4+) is not converged because it
#   has no `pmset` key, no profile payload, and no command-line setter. Its value
#   lives in a private NSKeyedArchiver blob keyed to a live owning task, so
#   writing it by hand is unsupported. It stays a one-time manual setting (see
#   MANUAL.md), which is the backstop rather than a second gate: the firmware
#   gate is the only automatic cap, and the helper has regressed on macOS 26.x.
#
# Manual conflict proof, needs root, diagnostic only:
#   sudo /usr/local/co.palokaj.battery/smc -k CHWA -r   # 01 means engaged

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

# The helper keeps state in the console user's HOME, so convergence is scoped to them.
# WHY: a headless/SSH activation has no session, so warn instead of failing the
#   apply. The machine is unattended, not misconfigured.
if ! _nucleus_resolve_console_user; then
  warn -l power "no console user session; skipped ${charge_limit_percent}% charge-limit convergence."
  exit 0
fi

if [ -n "$battery_cli" ]; then
  # WHY -H: without it sudo inherits HOME=/var/root, and the helper writes its
  #   state where the console user cannot.
  # WHY the redirect: the helper forks a nohup daemon that inherits the pipe
  #   write end, so an unpiped `./scripts/bootstrap.sh apply ... | <cmd>` hangs
  #   forever. The exit code is still checked; the helper logs to
  #   ~/.battery/battery.log for post-failure detail.
  if ! /usr/bin/sudo -H -u "$_nucleus_console_user" "$battery_cli" maintain "$charge_limit_percent" </dev/null >/dev/null 2>&1; then
    die -l power "battery maintain ${charge_limit_percent} failed for user '$_nucleus_console_user'."
  fi
elif [ -d "$battery_app" ]; then
  warn -l power "battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command."
else
  warn -l power "no supported battery charge-limit tool found (expected /usr/local/bin/battery)."
fi
