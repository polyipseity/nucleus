#!/usr/bin/env bash
# Tests for src/scripts/lib/macos-fskit.sh — the FSKit module-state probe and the
# kill-and-respawn repair path.
#
# The probe decides whether a mount attempt is skipped, so its contract matters
# in both directions: a readable list must answer enabled/disabled precisely, and
# an unreadable one must answer "unknown" rather than "disabled" (a probe failure
# that reads as a missing module would skip a mount that could have succeeded).
# The repair must report failure when the daemon does not come back, because the
# caller then stops the mount instead of retrying into the same wedge.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly SCRIPT_DIR REPO_ROOT
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/macos-fskit.sh
. "$REPO_ROOT/src/scripts/lib/macos-fskit.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin" "$_tmp/home/Library/Group Containers/group.com.apple.fskit.settings"
export HOME="$_tmp/home"
readonly _tmp
_plist="$(fskit_settings_plist)"
export PATH="$_tmp/bin:$PATH"

export FAKE_PLUTIL_STATUS FAKE_FSKIT_LISTING FAKE_FSKIT_PIDS FAKE_FSKIT_COUNTER FAKE_KILLALL_LOG FAKE_KILLALL_STATUS

cat >"$_tmp/bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
case "${1:-}" in
-p)
  printf '%s\n' "${FAKE_FSKIT_LISTING:-}"
  exit "${FAKE_PLUTIL_STATUS:-0}"
  ;;
esac
exit 1
FAKE_PLUTIL

# FAKE_FSKIT_PIDS — PIDs answered by successive `launchctl print` calls, the last
# one repeating. A daemon that never respawns answers the same PID every time.
cat >"$_tmp/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
print)
  _n=0
  if [ -f "$FAKE_FSKIT_COUNTER" ]; then _n="$(cat "$FAKE_FSKIT_COUNTER")"; fi
  _n=$((_n + 1))
  printf '%s' "$_n" >"$FAKE_FSKIT_COUNTER"
  _pid=""
  _i=0
  for _candidate in ${FAKE_FSKIT_PIDS:-}; do
    _i=$((_i + 1))
    _pid="$_candidate"
    if [ "$_i" -ge "$_n" ]; then break; fi
  done
  if [ -n "$_pid" ]; then printf 'pid = %s\n' "$_pid"; fi
  ;;
esac
exit 0
FAKE_LAUNCHCTL

cat >"$_tmp/bin/killall" <<'FAKE_KILLALL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_KILLALL_LOG"
exit "${FAKE_KILLALL_STATUS:-0}"
FAKE_KILLALL

cat >"$_tmp/bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
exec "$@"
FAKE_SUDO
chmod +x "$_tmp/bin/plutil" "$_tmp/bin/launchctl" "$_tmp/bin/killall" "$_tmp/bin/sudo"

assert_eq() { # <test name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    assert_pass "$1"
  else
    assert_fail "$1" "expected '$2', got '$3'"
  fi
}

assert_mentions() { # <slug> <haystack> <needle>
  case "$2" in
  *"$3"*) assert_pass "$1 mentions '$3'" ;;
  *) assert_fail "$1" "output did not mention '$3': $2" ;;
  esac
}

section "macos-fskit" "module state probe"

: >"$_plist"
FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
  1 => "io.macfuse.app.fsmodule.macfuse"
]'
assert_eq "a listed module reads as enabled" "enabled" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"
assert_eq "an unlisted module reads as disabled" "disabled" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse-other)"

FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
  1 => "io.macfuse.app.fsmodule.macfuse-local"
]'
assert_eq "the -local variant keeps macFUSE enabled" "enabled" "$(fskit_macfuse_module_state)"

FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
]'
assert_eq "a list without macFUSE reads as disabled" "disabled" "$(fskit_macfuse_module_state)"

# WHY: the probe gates a mount attempt, so a failed probe must not read as a
# missing module — that would skip a mount that could have succeeded.
FAKE_FSKIT_LISTING=""
FAKE_PLUTIL_STATUS=1
assert_eq "a failed probe reads as unknown" "unknown" "$(fskit_module_state io.macfuse.app.fsmodule.macfuse)"
FAKE_PLUTIL_STATUS=0

rm -f "$_plist"
assert_eq "a missing module list reads as unknown" "unknown" "$(fskit_macfuse_module_state)"
: >"$_plist"

section "macos-fskit" "daemon state and repair"

export FAKE_FSKIT_COUNTER="$_tmp/launchctl.count"
export FAKE_KILLALL_LOG="$_tmp/killall.log"
: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"

FAKE_FSKIT_PIDS='4242'
assert_eq "a running daemon reports its pid" "4242" "$(fskit_daemon_pid)"
assert_eq "a running daemon reads as running" "running" "$(fskit_daemon_state)"

FAKE_FSKIT_PIDS=''
: >"$FAKE_FSKIT_COUNTER"
assert_eq "an absent daemon has no pid" "" "$(fskit_daemon_pid)"
assert_eq "an absent daemon reads as stopped" "stopped" "$(fskit_daemon_state)"

: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='100 200'
if fskit_restart_daemon 5; then
  assert_pass "a daemon that respawns reports success"
else
  assert_fail "fskit-restart" "the restart failed although the daemon respawned with a new pid"
fi
assert_mentions "the restart" "$(cat "$FAKE_KILLALL_LOG")" "fskitd"

: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='100 100'
if fskit_restart_daemon 1 2>"$_tmp/restart.err"; then
  assert_fail "fskit-restart-stale" "a daemon that kept its pid was reported as restarted"
else
  assert_pass "a daemon that never respawns reports failure"
fi
assert_mentions "the failed restart" "$(cat "$_tmp/restart.err")" "did not restart"

: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='300 400'
FAKE_KILLALL_STATUS=1
if fskit_restart_daemon 1 2>"$_tmp/killfail.err"; then
  assert_fail "fskit-restart-killfail" "a failed killall was reported as a successful restart"
else
  assert_pass "a failed killall reports failure"
fi
assert_mentions "the failed killall" "$(cat "$_tmp/killfail.err")" "killall fskitd"
FAKE_KILLALL_STATUS=0

assert_mentions "the remedy" "$(fskit_remedy)" "killall fskitd"

section "macos-fskit" "provider repair"

# WHY: the repair has to distinguish "the subsystem needed a restart" from "the
# module is gone" — the second needs the operator, and only an error says so.
: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='100 200'
FAKE_FSKIT_LISTING='[
  0 => "io.macfuse.app.fsmodule.macfuse"
]'
assert_eq "a repaired provider reports ok" "ok" "$(fskit_repair_provider 5)"

: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='100 200'
FAKE_FSKIT_LISTING='[
  0 => "com.apple.fskit.exfat"
]'
FAKE_FSKIT_REPAIR_OUT="$(fskit_repair_provider 5 2>"$_tmp/repair-disabled.err")" || :
assert_eq "a restart without the module reports module-disabled" "module-disabled" "$FAKE_FSKIT_REPAIR_OUT"
assert_mentions "the disabled-module report" "$(cat "$_tmp/repair-disabled.err")" "Login Items & Extensions"

: >"$FAKE_KILLALL_LOG"
: >"$FAKE_FSKIT_COUNTER"
FAKE_FSKIT_PIDS='100 100'
if fskit_repair_provider 1 2>"$_tmp/repair-fail.err"; then
  assert_fail "fskit-repair-daemon" "a daemon that never respawned was reported as repaired"
else
  assert_pass "a daemon that never respawns fails the repair"
fi

finish_tests
