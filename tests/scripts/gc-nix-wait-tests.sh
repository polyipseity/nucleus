#!/usr/bin/env bash
# Tests: run_nix_gc_with_wait_progress reports the lock wait, enforces the
# deadline, kills and reaps the child, and passes output through otherwise.
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
# shellcheck source=../../src/scripts/lib/gc-nix.sh
. "$REPO_ROOT/src/scripts/lib/gc-nix.sh"

_stub="$(mktemp -d)/nix-collect-garbage"
cat >"$_stub" <<'STUB'
#!/usr/bin/env bash
printf 'stub-pid=%s\n' "$$"
printf 'arguments=%s\n' "$*"
printf 'waiting for the big garbage collector lock...\n'
exec sleep "${STUB_SLEEP:-0}"
STUB
chmod +x "$_stub"
export NUCLEUS_NIX_COLLECT_GARBAGE_BIN="$_stub"

_case_deadline_kills_the_child() {
  local _t0 _out _rc _elapsed _pid
  _t0="$(date +%s)"
  _out="$(STUB_SLEEP=60 NUCLEUS_GC_LOCK_WAIT_DEADLINE=2 NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL=1 \
    run_nix_gc_with_wait_progress 7d 2>&1)"
  _rc=$?
  _elapsed=$(($(date +%s) - _t0))
  _pid="$(printf '%s\n' "$_out" | sed -n 's/^stub-pid=//p' | head -1)"

  if [ "$_rc" -eq 1 ]; then
    assert_pass "expired run exits 1"
  else
    assert_fail "expired run exits 1" "rc=$_rc output=$_out"
  fi
  if [ "$_elapsed" -lt 20 ]; then
    assert_pass "expiry is enforced near the deadline (${_elapsed}s)"
  else
    assert_fail "expiry is enforced near the deadline" "took ${_elapsed}s"
  fi
  case "$_out" in
  *"waiting for the Nix garbage collector lock (elapsed"*) assert_pass "lock wait progress is reported" ;;
  *) assert_fail "lock wait progress is reported" "output: $_out" ;;
  esac
  case "$_out" in
  *"timed out waiting for nix-collect-garbage"*) assert_pass "expiry is reported" ;;
  *) assert_fail "expiry is reported" "output: $_out" ;;
  esac
  if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
    assert_pass "the child is killed and reaped"
  else
    assert_fail "the child is killed and reaped" "pid=$_pid still alive"
  fi
}

_case_success_passes_output_through() {
  local _out _rc
  _out="$(STUB_SLEEP=0 run_nix_gc_with_wait_progress 7d 2>&1)"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "successful run exits 0"
  else
    assert_fail "successful run exits 0" "rc=$_rc output=$_out"
  fi
  case "$_out" in
  *"arguments=--delete-older-than 7d"*) assert_pass "expiry reaches the command" ;;
  *) assert_fail "expiry reaches the command" "output: $_out" ;;
  esac
  case "$_out" in
  *"waiting for the big garbage collector lock"*) assert_pass "child output is passed through" ;;
  *) assert_fail "child output is passed through" "output: $_out" ;;
  esac
  if [[ "$_out" != *"timed out"* ]]; then
    assert_pass "no expiry on a completed run"
  else
    assert_fail "no expiry on a completed run" "output: $_out"
  fi
}

_case_zero_deadline_disables_the_bound() {
  local _t0 _out _rc _elapsed
  _t0="$(date +%s)"
  _out="$(STUB_SLEEP=3 NUCLEUS_GC_LOCK_WAIT_DEADLINE=0 run_nix_gc_with_wait_progress 7d 0 2>&1)"
  _rc=$?
  _elapsed=$(($(date +%s) - _t0))
  if [ "$_rc" -eq 0 ] && [ "$_elapsed" -ge 3 ]; then
    assert_pass "zero deadline runs to completion (${_elapsed}s)"
  else
    assert_fail "zero deadline runs to completion" "rc=$_rc elapsed=${_elapsed}s output=$_out"
  fi
}

_case_invalid_deadline_falls_back_to_the_default() {
  local _out _rc
  _out="$(STUB_SLEEP=0 NUCLEUS_GC_LOCK_WAIT_DEADLINE=banana NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL=banana \
    run_nix_gc_with_wait_progress 7d 2>&1)"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "invalid deadline does not break a short run"
  else
    assert_fail "invalid deadline does not break a short run" "rc=$_rc output=$_out"
  fi
}

section "1" "bounded nix-collect-garbage"
_case_deadline_kills_the_child
_case_success_passes_output_through
_case_zero_deadline_disables_the_bound
_case_invalid_deadline_falls_back_to_the_default

finish_tests
