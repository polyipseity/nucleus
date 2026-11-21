#!/usr/bin/env bash
# Tests: store_lock_run_bounded keeps output intact, reports the lock wait, and
# kills the whole process group at the deadline.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=../../src/scripts/lib/bash-guard.sh
. "$REPO_ROOT/src/scripts/lib/bash-guard.sh"
bash_guard_require 5 1 test
init_test_state
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/store-lock.sh
. "$REPO_ROOT/src/scripts/lib/store-lock.sh"

_case_output_survives_without_a_wait() {
  local _seen _out _rc
  _seen="$(mktemp)"
  _out="$(store_lock_run_bounded 5 1 "waiting for the big garbage collector lock" "$_seen" \
    -- bash -c 'echo first; echo second; exit 0' 2>&1)"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "a clean command exits 0"
  else
    assert_fail "a clean command exits 0" "rc=$_rc output=$_out"
  fi
  case "$_out" in
  *first*second*) assert_pass "stdout is passed through" ;;
  *) assert_fail "stdout is passed through" "output: $_out" ;;
  esac
  if [[ "$_out" != *"waiting for the Nix store garbage collector lock"* ]]; then
    assert_pass "no wait line without a lock message"
  else
    assert_fail "no wait line without a lock message" "output: $_out"
  fi
}

_case_failure_status_is_preserved() {
  local _seen _rc
  _seen="$(mktemp)"
  store_lock_run_bounded 5 1 "lock" "$_seen" -- bash -c 'exit 7' >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -eq 7 ]; then
    assert_pass "a failing command keeps its status"
  else
    assert_fail "a failing command keeps its status" "rc=$_rc"
  fi
}

_case_deadline_kills_the_group() {
  local _seen _out _rc _t0 _elapsed _child_pid _pidfile
  _seen="$(mktemp)"
  _pidfile="$(mktemp)"
  _t0="$(date +%s)"
  # shellcheck disable=SC2016 # check-suppress:suppression_doc: inner bash -c keeps $! and $0 for child shell expansion
  local _child_cmd='sleep 120 & echo "$!" >"$0"; echo "waiting for the big garbage collector lock..." >&2; sleep 120'
  _out="$(
    store_lock_run_bounded 2 1 "waiting for the big garbage collector lock" "$_seen" \
      -- bash -c "$_child_cmd" \
      "$_pidfile" 2>&1
  )"
  _rc=$?
  _elapsed=$(($(date +%s) - _t0))
  _child_pid="$(cat "$_pidfile")"

  if [ "$_rc" -eq 124 ]; then
    assert_pass "an expired run returns 124"
  else
    assert_fail "an expired run returns 124" "rc=$_rc output=$_out"
  fi
  assert_elapsed_below "the deadline is enforced" 20 "$_elapsed" 120
  case "$_out" in
  *"waiting for the Nix store garbage collector lock (elapsed"*) assert_pass "the wait is reported" ;;
  *) assert_fail "the wait is reported" "output: $_out" ;;
  esac
  if [ -n "$_child_pid" ] && ! kill -0 "$_child_pid" 2>/dev/null; then
    assert_pass "the whole process group is killed"
  else
    assert_fail "the whole process group is killed" "child pid $_child_pid survived"
  fi
}

_case_zero_deadline_never_aborts() {
  local _seen _rc
  _seen="$(mktemp)"
  store_lock_run_bounded 0 1 "lock" "$_seen" -- bash -c 'sleep 2; exit 0' >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "a zero deadline never aborts"
  else
    assert_fail "a zero deadline never aborts" "rc=$_rc"
  fi
}

_case_invalid_deadline_is_rejected() {
  local _seen _rc
  _seen="$(mktemp)"
  store_lock_run_bounded banana 1 "lock" "$_seen" -- true >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -eq 2 ]; then
    assert_pass "a non-numeric deadline is a hard error"
  else
    assert_fail "a non-numeric deadline is a hard error" "rc=$_rc"
  fi
}

section "1" "bounded store-lock wait"
_case_output_survives_without_a_wait
_case_failure_status_is_preserved
_case_deadline_kills_the_group
_case_zero_deadline_never_aborts
_case_invalid_deadline_is_rejected

finish_tests
