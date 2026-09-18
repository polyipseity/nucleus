#!/usr/bin/env bash
# Tests for rescan_pbs_services in src/scripts/lib/macos-launch-services.sh.
#
# The function exists to build one exact launchctl command line:
#
#   launchctl asuser <uid> <sudo> -H -u <user> <pbs> -update
#
# Every part of that line is load-bearing and none of it is observable from the
# function's output, which is why the suite drives the extracted function
# against recorder stubs instead of asserting on the source text:
#   * the command has to run through `asuser <uid>` so pbs rescans the console
#     user's Services cache instead of root's;
#   * `sudo -H -u <user>` re-enters as the console user, so a substituted uid or
#     user silently rescans the wrong account's cache;
#   * the pbs binary is a caller argument (the Nix wrapper supplies the store
#     path), so a hardcoded path would run a different build than the one the
#     caller resolved;
#   * `-update` is the flag that forces a complete rescan — pbs rejects a bare
#     invocation with a usage message and exit status 1, so a dropped flag turns
#     the rescan into a failure.
#
# The stubs run from a mktemp tree and never touch ~/Library/Services, pbs, or
# any other system state.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LIB_SH="$SCRIPT_DIR/../../src/scripts/lib/macos-launch-services.sh"

# Fail closed: without the extracted function every case below would call an
# undefined command and the suite would report a green tally for a rescan that
# never ran.
RESCAN_FUNC="$(extract_func rescan_pbs_services "$LIB_SH")"
if [ -z "$RESCAN_FUNC" ]; then
  assert_fail "rescan_pbs_services is defined in macos-launch-services.sh" \
    "extract_func rescan_pbs_services returned nothing from $LIB_SH"
  finish_tests
fi

eval "$RESCAN_FUNC"

# Distinctive identity: neither value exists on the machine running the suite,
# so a uid or user picked up from the environment instead of from the arguments
# shows up as a mismatch rather than as a coincidental pass.
TEST_UID="4242"
TEST_USER="testuser"

# make_argv_recorder <path> <log> — executable that appends its argv to <log>,
# one space-joined line per invocation.
make_argv_recorder() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$*" >>"$2"
STUB
  chmod +x "$1"
}

# make_self_path_recorder <path> <marker> — executable that appends its own path
# to <marker>, the way a real binary identifies which binary ran.
make_self_path_recorder() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$0" >>"$2"
STUB
  chmod +x "$1"
}

# make_exec_launchctl <path> — launchctl stand-in that runs the command it was
# handed. Real launchctl runs that command inside the target session, which is
# how the suite observes the binary rescan_pbs_services actually chose.
make_exec_launchctl() {
  cat >"$1" <<'STUB'
#!/bin/sh
# asuser <uid> <sudo> -H -u <user> <command> [args...]: the six leading words
# are launchctl's own prologue, the rest is the command to run.
shift 6
"$@"
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

test_rescan_invokes_launchctl_once_with_the_expected_argv() {
  local work launchctl pbs sudo log status=0 invocations recorded expected
  work="$(mktemp -d)"
  launchctl="$work/launchctl"
  # The argv recorder never executes the command it is handed, so the pbs path
  # below is only a value to compare the recorded argv against.
  pbs="$work/pbs"
  sudo="$work/sudo"
  log="$work/launchctl.argv"
  make_argv_recorder "$launchctl" "$log"

  rescan_pbs_services "$pbs" "$launchctl" "$sudo" "$TEST_UID" "$TEST_USER" || status=$?

  invocations="$(recorded_invocations "$log")"
  if [ "$status" -eq 0 ] && [ "$invocations" = "1" ]; then
    assert_pass "rescan runs launchctl exactly once"
  else
    assert_fail "rescan runs launchctl exactly once" \
      "expected 1 invocation, got $invocations (exit $status)"
  fi

  # Full-string equality, not a prefix test: the whole command line is the
  # contract, including `-update` as the last argument.
  recorded="$(recorded_line "$log" 1)"
  expected="asuser $TEST_UID $sudo -H -u $TEST_USER $pbs -update"
  if [ "$recorded" = "$expected" ]; then
    assert_pass "rescan passes asuser <uid> <sudo> -H -u <user> <pbs> -update"
  else
    assert_fail "rescan passes asuser <uid> <sudo> -H -u <user> <pbs> -update" \
      "expected [$expected], got [$recorded]"
  fi
  rm -rf "$work"
}

test_rescan_invokes_the_pbs_binary_it_was_passed() {
  local work launchctl pbs sudo marker status=0 invoked
  work="$(mktemp -d)"
  launchctl="$work/launchctl"
  # A path that only the caller can supply: a hardcoded pbs would leave the
  # marker empty instead of running this stub.
  pbs="$work/pbs-from-test"
  sudo="$work/sudo"
  marker="$work/pbs.invoked"
  make_exec_launchctl "$launchctl"
  make_self_path_recorder "$pbs" "$marker"

  rescan_pbs_services "$pbs" "$launchctl" "$sudo" "$TEST_UID" "$TEST_USER" || status=$?

  invoked="$(recorded_line "$marker" 1)"
  if [ "$status" -eq 0 ] && [ "$invoked" = "$pbs" ]; then
    assert_pass "rescan runs the pbs binary it was passed in, not a hardcoded path"
  else
    assert_fail "rescan runs the pbs binary it was passed in, not a hardcoded path" \
      "expected the stub at [$pbs] to run, marker held [$invoked] (exit $status)"
  fi
  rm -rf "$work"
}

test_rescan_passes_uid_and_user_through_verbatim() {
  local work launchctl pbs sudo log status=0 first second
  work="$(mktemp -d)"
  launchctl="$work/launchctl"
  pbs="$work/pbs"
  sudo="$work/sudo"
  log="$work/launchctl.argv"
  make_argv_recorder "$launchctl" "$log"

  rescan_pbs_services "$pbs" "$launchctl" "$sudo" "$TEST_UID" "$TEST_USER" || status=$?
  # A second, unrelated identity: if the function used a hardcoded uid or user,
  # or read the current account, one of the two runs has to disagree.
  rescan_pbs_services "$pbs" "$launchctl" "$sudo" "7" "other-user" || status=$?

  first="$(recorded_line "$log" 1)"
  second="$(recorded_line "$log" 2)"
  if [ "$status" -eq 0 ] && [ "$first" = "asuser $TEST_UID $sudo -H -u $TEST_USER $pbs -update" ]; then
    assert_pass "rescan passes the given uid and user through verbatim"
  else
    assert_fail "rescan passes the given uid and user through verbatim" \
      "expected [asuser $TEST_UID $sudo -H -u $TEST_USER $pbs -update], got [$first] (exit $status)"
  fi

  if [ "$second" = "asuser 7 $sudo -H -u other-user $pbs -update" ]; then
    assert_pass "rescan uses the second identity it was given, not the first"
  else
    assert_fail "rescan uses the second identity it was given, not the first" \
      "expected [asuser 7 $sudo -H -u other-user $pbs -update], got [$second]"
  fi
  rm -rf "$work"
}

test_rescan_fails_when_launchctl_fails() {
  local work launchctl pbs sudo status=0
  work="$(mktemp -d)"
  launchctl="$work/launchctl"
  pbs="$work/pbs"
  sudo="$work/sudo"
  make_exit_stub "$launchctl" 7

  rescan_pbs_services "$pbs" "$launchctl" "$sudo" "$TEST_UID" "$TEST_USER" || status=$?

  # The caller (src/scripts/services/refresh-services-menu.sh) warns on a
  # non-zero return, so a swallowed failure would turn a failed rescan into a
  # silent "Services menu refreshed" claim.
  if [ "$status" -ne 0 ]; then
    assert_pass "rescan returns non-zero when launchctl fails (exit $status)"
  else
    assert_fail "rescan returns non-zero when launchctl fails" \
      "expected a non-zero return from a launchctl stub exiting 7, got 0"
  fi
  rm -rf "$work"
}

# ---- Command line ----

test_rescan_invokes_launchctl_once_with_the_expected_argv
test_rescan_invokes_the_pbs_binary_it_was_passed
test_rescan_passes_uid_and_user_through_verbatim

# ---- Exit status ----

test_rescan_fails_when_launchctl_fails

finish_tests
