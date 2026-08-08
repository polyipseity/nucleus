#!/usr/bin/env bash
# Keep charge capped at 80 % to reduce long-term battery wear on a mostly
# docked development machine.
#
# On macOS 15+, bclm no longer works due kernel entitlement enforcement.
# Prefer the maintained `battery` CLI (installed by the `battery` cask) and
# run it as the active console user so user-scoped launch-agent state stays
# in that user's home directory.
#
# bclm is retained as a fallback only for older macOS versions.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

macos_major="$(/usr/bin/sw_vers -productVersion 2>/dev/null | /usr/bin/awk -F. '{print $1}')"

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
        echo "power: battery maintain 80 failed for user '$_nucleus_console_user'." >&2
      fi
    elif [ -x /opt/homebrew/bin/bclm ]; then
      if [ -n "$macos_major" ] && [ "$macos_major" -ge 15 ]; then
        echo "power: bclm is unsupported on macOS >= 15; install and initialize the battery app to enforce 80% charge limit." >&2
      else
        if ! /opt/homebrew/bin/bclm write 80; then
          echo "power: bclm write 80 failed." >&2
        fi
        if ! /opt/homebrew/bin/bclm persist; then
          echo "power: bclm persist failed." >&2
        fi
      fi
    elif [ -d "$battery_app" ]; then
      echo "power: battery.app is installed but the battery CLI is unavailable; open battery.app once and complete setup to install the helper command." >&2
    else
      echo "power: no supported battery charge-limit tool found (expected /usr/local/bin/battery or /opt/homebrew/bin/bclm)." >&2
    fi
