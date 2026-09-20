#!/usr/bin/env bash
# Keep charge capped at 80 % to reduce long-term battery wear on a mostly
# docked development machine.
#
# The `battery` CLI (installed by the `battery` cask) is the enforcement path.
# It runs as the active console user so user-scoped launch-agent state stays in
# that user's home directory, and it writes the SMC charging gate plus a
# headless LaunchAgent (com.battery.app) so the cap persists without the tray
# being open.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

battery_app="/Applications/battery.app"
battery_cli=""
for candidate in /usr/local/bin/battery /usr/local/co.palokaj.battery/battery; do
  if [ -x "$candidate" ]; then
    battery_cli="$candidate"
    break
  fi
done

if [ -n "$battery_cli" ] && _nucleus_resolve_console_user; then
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
  if ! /usr/bin/sudo -H -u "$_nucleus_console_user" "$battery_cli" maintain 80 </dev/null >/dev/null 2>&1; then
    die -l power "battery maintain 80 failed for user '$_nucleus_console_user'."
  fi
elif [ -d "$battery_app" ]; then
  warn -l power "battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command."
else
  warn -l power "no supported battery charge-limit tool found (expected /usr/local/bin/battery)."
fi
