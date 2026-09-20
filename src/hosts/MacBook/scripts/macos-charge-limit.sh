#!/usr/bin/env bash
# Keep charge capped at 80 % to reduce long-term battery wear on a mostly
# docked development machine.
#
# Two independent gates are converged to the same 80 % ceiling:
#
#   1. `battery` CLI (installed by the `battery` cask) — writes the SMC charging
#      gate and installs a headless LaunchAgent (com.battery.app) so the cap
#      persists without the tray being open.
#   2. Native macOS Charge Limit (macOS 26.4+) — driven through a Shortcuts
#      shortcut with the "Set Battery Charge Limit" action.
#
# Both gates must be open for charging to happen, so the effective ceiling is
# the lower of the two; setting both to 80 % makes the pair convergent by
# construction.
#
# WHY: both gates are kept even though either one alone caps charge at 80 %.
#   They are independent mechanisms, and the third-party one can be broken by an
#   OS update — the `battery` CLI has had exactly such regressions on macOS
#   26.x — which is what the native gate insures against.  Do not delete one as
#   "redundant".
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

# WHY: Shortcuts workflows cannot be authored from the command line, so this
#   shortcut is created once by hand (see MANUAL.md).  Its name is the contract
#   between that one-time step and this script.
native_charge_limit_shortcut="Set Charge Limit 80"

# The native Charge Limit shipped in macOS 26.4; earlier releases have no
# equivalent setting to converge, and the `battery` CLI gate covers them alone.
native_charge_limit_major=26
native_charge_limit_minor=4

macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
case "$macos_version" in
*.*)
  macos_minor="${macos_version#*.}"
  macos_minor="${macos_minor%%.*}"
  ;;
*)
  macos_minor=0
  ;;
esac
case "${macos_major}${macos_minor}" in
'' | *[!0-9]*)
  die -l power "unexpected macOS version '$macos_version'."
  ;;
esac

battery_app="/Applications/battery.app"
battery_cli=""
for candidate in /usr/local/bin/battery /usr/local/co.palokaj.battery/battery; do
  if [ -x "$candidate" ]; then
    battery_cli="$candidate"
    break
  fi
done

# Both gates are console-user scoped: the `battery` helper keeps its state in
# that user's HOME, and Shortcuts shortcuts belong to that user.
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

# ---- native macOS Charge Limit (macOS 26.4+) --------------------------------
# WHY: the native setting has no pmset key and no configuration-profile
#   payload, so the Shortcuts action is its only automation surface.
if [ "$macos_major" -lt "$native_charge_limit_major" ] ||
  { [ "$macos_major" -eq "$native_charge_limit_major" ] && [ "$macos_minor" -lt "$native_charge_limit_minor" ]; }; then
  notice -l power "macOS $macos_version has no native charge limit; the battery CLI gate alone caps charge at ${charge_limit_percent}%."
else
  # WHY: `shortcuts` talks to a helper inside the GUI session, so the command
  #   must enter that session — a plain `sudo -u` from the root activation
  #   context fails with "Couldn't communicate with a helper application".
  if ! shortcut_list="$(/usr/bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/shortcuts list </dev/null 2>&1)"; then
    warn -l power "Shortcuts helper unreachable for user '$_nucleus_console_user'; native ${charge_limit_percent}% gate not converged: $shortcut_list"
  else
    shortcut_present=false
    while IFS= read -r listed_shortcut; do
      if [ "$listed_shortcut" = "$native_charge_limit_shortcut" ]; then
        shortcut_present=true
      fi
    done <<EOF
$shortcut_list
EOF

    if [ "$shortcut_present" = false ]; then
      # WHY: the shortcut cannot be authored from the command line, so its
      #   absence is a documented one-time manual prerequisite (MANUAL.md)
      #   rather than a convergence failure — the `battery` CLI gate still caps
      #   charge at 80 % in the meantime.
      warn -l power "shortcut '$native_charge_limit_shortcut' is missing; create it once (see MANUAL.md) to converge the native ${charge_limit_percent}% gate."
    elif ! shortcut_output="$(/usr/bin/launchctl asuser "$_nucleus_console_uid" /usr/bin/sudo -H -u "$_nucleus_console_user" /usr/bin/shortcuts run "$native_charge_limit_shortcut" </dev/null 2>&1)"; then
      die -l power "shortcut '$native_charge_limit_shortcut' failed; native ${charge_limit_percent}% charge limit is not converged: $shortcut_output"
    fi
  fi
fi
