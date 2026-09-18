#!/usr/bin/env bash
# End-to-end guard for src/scripts/services/refresh-services-menu.sh.
#
# The sibling suite (macos-refresh-services-discovery-tests.sh) drives the
# extracted rescan_pbs_services function directly, so deleting the call to it
# from the script would leave that suite green. This suite runs the whole
# script under recorder stubs and fails when the call site disappears, when its
# arguments are reordered, when the console-user indirection is dropped, or when
# the pbs binary stops being forwarded from argv.
#
# The script first calls refresh_services_menu, whose body runs only when
# uname(1) reports Darwin and kills cfprefsd, lsregister, pbs, and Finder by
# absolute path. Absolute paths cannot be intercepted from PATH, so the suite
# prepends a stub uname that prints Linux: the composite becomes a no-op while
# the script still reaches its console-user branch and rescan. That stub is
# load-bearing — without it this suite would kill live services.
#
# Every stub lives in a mktemp tree. The suite never touches
# ~/Library/Services, pbs, Finder, or any other system state.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

SUBJECT_SH="$SCRIPT_DIR/../../src/scripts/services/refresh-services-menu.sh"
if [ ! -f "$SUBJECT_SH" ]; then
  assert_fail "refresh-services-menu.sh exists" "not found at $SUBJECT_SH"
  finish_tests
fi

# ---- /dev/console branch selection ----
#
# The script takes the rescan path only when _nucleus_resolve_console_user
# succeeds, which requires a non-root owner of /dev/console. The same probe
# decides the expectation here, so the applicable contract is asserted instead
# of skipped.
CONSOLE_UID="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || true)"
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
  CONSOLE_PRESENT=1
  BRANCH="console-user branch (uid $CONSOLE_UID)"
  EXPECTED_INVOCATIONS=1
else
  CONSOLE_PRESENT=0
  BRANCH="headless branch (no console user)"
  EXPECTED_INVOCATIONS=0
fi

# ---- Stubs ----

# make_linux_uname <path> — prints Linux so refresh_services_menu's Darwin case
# never matches and its absolute-path kills never run.
make_linux_uname() {
  cat >"$1" <<'STUB'
#!/bin/sh
printf 'Linux\n'
STUB
  chmod +x "$1"
}

# make_recording_exec_launchctl <path> <log> — records its argv as one
# space-joined line and then executes the command it was handed. Real launchctl
# runs that command inside the target session, which is how the suite observes
# the exact pbs binary the script chose. The six leading words are launchctl's
# own asuser prologue; the rest is the command to run.
make_recording_exec_launchctl() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$*" >>"$2"
shift 6
"\$@"
STUB
  chmod +x "$1"
}

# make_self_path_recorder <path> <marker> — records its own path, the way a real
# binary identifies which binary ran.
make_self_path_recorder() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$0" >>"$2"
STUB
  chmod +x "$1"
}

# make_exit_stub <path> <status> — executable that exits with a fixed status.
make_exit_stub() {
  cat >"$1" <<STUB
#!/bin/sh
exit $2
STUB
  chmod +x "$1"
}

# recorded_invocations <log> — how many invocations the recorder logged.
recorded_invocations() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0'
  fi
}

# recorded_line <log> <n> — the n-th recorded invocation, empty when absent.
recorded_line() {
  if [ -f "$1" ]; then
    sed -n "$2p" "$1"
  fi
}

# ---- One subject run, shared by every assertion ----

WORK=""
WORK_PBS=""
WORK_LAUNCHCTL=""
WORK_SUDO=""
RUN_STATUS=0
RUN_LOG=""
RUN_MARKER=""
RUN_STDERR=""
EXPECTED_LINE=""
EXPECTED_PBS_MARKER=""
FINDER_BEFORE=""
FINDER_AFTER=""
PBS_BEFORE=""
PBS_AFTER=""

run_subject_once() {
  WORK="$(mktemp -d)"
  trap 'rm -rf "${WORK:-}"' EXIT
  mkdir -p "$WORK/path"
  WORK_PBS="$WORK/pbs"
  WORK_LAUNCHCTL="$WORK/launchctl"
  WORK_SUDO="$WORK/sudo"
  RUN_LOG="$WORK/launchctl.argv"
  RUN_MARKER="$WORK/pbs.invoked"
  RUN_STDERR="$WORK/subject.stderr"

  make_linux_uname "$WORK/path/uname"
  make_recording_exec_launchctl "$WORK_LAUNCHCTL" "$RUN_LOG"
  make_self_path_recorder "$WORK_PBS" "$RUN_MARKER"
  make_exit_stub "$WORK_SUDO" 0

  FINDER_BEFORE="$(pgrep -x Finder 2>/dev/null || true)"
  PBS_BEFORE="$(pgrep -x pbs 2>/dev/null || true)"

  RUN_STATUS=0
  PATH="$WORK/path:$PATH" bash "$SUBJECT_SH" "$WORK_PBS" "$WORK_LAUNCHCTL" "$WORK_SUDO" \
    >"$WORK/subject.stdout" 2>"$RUN_STDERR" || RUN_STATUS=$?

  FINDER_AFTER="$(pgrep -x Finder 2>/dev/null || true)"
  PBS_AFTER="$(pgrep -x pbs 2>/dev/null || true)"

  if [ "$CONSOLE_PRESENT" -eq 1 ]; then
    EXPECTED_LINE="asuser $CONSOLE_UID $WORK_SUDO -H -u $CONSOLE_USER $WORK_PBS -update"
    EXPECTED_PBS_MARKER="$WORK_PBS"
  else
    EXPECTED_LINE=""
    EXPECTED_PBS_MARKER=""
  fi
}

# ---- Tests ----

test_subject_exits_zero() {
  section 1 "exit status"
  if [ "$RUN_STATUS" -eq 0 ]; then
    assert_pass "refresh-services-menu.sh exits 0"
  else
    assert_fail "refresh-services-menu.sh exits 0" \
      "expected 0, got $RUN_STATUS (stderr: $(cat "$RUN_STDERR"))"
  fi
}

test_rescan_call_site_is_wired() {
  section 2 "rescan call site"

  local invocations
  invocations="$(recorded_invocations "$RUN_LOG")"
  # Zero invocations on a host with a console user means the rescan call is gone
  # or its guard no longer fires — the exact regression the extracted-function
  # suite cannot see.
  if [ "$invocations" -eq "$EXPECTED_INVOCATIONS" ]; then
    assert_pass "refresh-services-menu.sh records $EXPECTED_INVOCATIONS launchctl invocation(s) on the $BRANCH"
  else
    assert_fail "refresh-services-menu.sh rescan call site" \
      "expected $EXPECTED_INVOCATIONS launchctl invocation(s) on the $BRANCH, got $invocations"
  fi
}

test_rescan_exact_argv() {
  section 3 "rescan argv"

  local recorded
  recorded="$(recorded_line "$RUN_LOG" 1)"
  # Full-string equality, not a prefix test: the whole line is the contract, so
  # reordering the uid/sudo/user arguments — or dropping -update — shows up here.
  if [ "$recorded" = "$EXPECTED_LINE" ]; then
    assert_pass "refresh-services-menu.sh passes asuser <uid> <sudo> -H -u <user> <pbs> -update"
  else
    assert_fail "refresh-services-menu.sh rescan argv" \
      "expected [$EXPECTED_LINE], got [$recorded]"
  fi
}

test_rescan_runs_the_pbs_binary_it_was_passed() {
  section 4 "pbs binary identity"

  local invoked
  invoked="$(recorded_line "$RUN_MARKER" 1)"
  # The recorder's launchctl stub executes the command it is handed, so the
  # marker proves the script forwarded its own argv instead of a hardcoded path.
  if [ "$invoked" = "$EXPECTED_PBS_MARKER" ]; then
    assert_pass "refresh-services-menu.sh runs the pbs binary it was passed in, not a hardcoded path"
  else
    assert_fail "refresh-services-menu.sh pbs binary" \
      "expected the stub at [$EXPECTED_PBS_MARKER] to run, marker held [$invoked]"
  fi
}

test_live_services_untouched() {
  section 5 "live processes untouched"

  if [ "$FINDER_BEFORE" = "$FINDER_AFTER" ] && [ "$PBS_BEFORE" = "$PBS_AFTER" ]; then
    assert_pass "suite leaves live Finder and pbs processes untouched"
  else
    assert_fail "live process drift" \
      "Finder [$FINDER_BEFORE] -> [$FINDER_AFTER], pbs [$PBS_BEFORE] -> [$PBS_AFTER]"
  fi
}

test_console_branch_contract() {
  section 6 "/dev/console branch"

  # Branch-adaptive: a present console owner means the script must rescan once;
  # a headless host means it must exit 0 with no rescan and emit the skip
  # warning. Either way the branch that applies is asserted, never skipped.
  local invocations
  invocations="$(recorded_invocations "$RUN_LOG")"
  if [ "$CONSOLE_PRESENT" -eq 1 ]; then
    if [ "$RUN_STATUS" -eq 0 ] && [ "$invocations" -eq 1 ]; then
      assert_pass "console user present -> script exits 0 and rescans once on the $BRANCH"
    else
      assert_fail "console-user branch contract" \
        "expected exit 0 and 1 rescan on the $BRANCH, got exit $RUN_STATUS with $invocations rescan(s)"
    fi
    if grep -q "no console user session" "$RUN_STDERR"; then
      assert_fail "console-user branch warning" \
        "console user is present but the script emitted the headless skip warning"
    else
      assert_pass "console user present -> no headless skip warning"
    fi
  else
    if [ "$RUN_STATUS" -eq 0 ] && [ "$invocations" -eq 0 ]; then
      assert_pass "no console user -> script exits 0 and skips the rescan on the $BRANCH"
    else
      assert_fail "headless branch contract" \
        "expected exit 0 and 0 rescans on the $BRANCH, got exit $RUN_STATUS with $invocations rescan(s)"
    fi
    if grep -q "no console user session" "$RUN_STDERR"; then
      assert_pass "no console user -> headless skip warning emitted"
    else
      assert_fail "headless skip warning" \
        "no console user, but the script did not warn that the rescan was skipped"
    fi
  fi
}

# ---- Run all tests ----

run_subject_once

test_subject_exits_zero
test_rescan_call_site_is_wired
test_rescan_exact_argv
test_rescan_runs_the_pbs_binary_it_was_passed
test_live_services_untouched
test_console_branch_contract

finish_tests
