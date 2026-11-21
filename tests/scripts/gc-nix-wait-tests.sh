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

_stub_dir="$(mktemp -d)"
_stub="$_stub_dir/nix-collect-garbage"
cat >"$_stub" <<'STUB'
#!/usr/bin/env bash
# WHY the pid file: a victim that dies before its first line of stdout still
# proves the reap, and the harness must not depend on the child winning a race
# against the deadline to record who it was. _STUB_DIR is exported by the suite.
printf '%s\n' "$$" >"${_STUB_DIR:?}/pid"
sleep "${STUB_START_DELAY:-0}"
printf 'stub-pid=%s\n' "$$"
printf 'arguments=%s\n' "$*"
printf 'waiting for the big garbage collector lock...\n'
exec sleep "${STUB_SLEEP:-0}"
STUB
chmod +x "$_stub"
export NUCLEUS_NIX_COLLECT_GARBAGE_BIN="$_stub"
_STUB_DIR="$_stub_dir"
export _STUB_DIR

_case_deadline_kills_the_child() {
  local _t0 _out _rc _elapsed _pid
  _t0="$(date +%s)"
  _out="$(STUB_SLEEP=60 NUCLEUS_GC_LOCK_WAIT_DEADLINE=2 NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL=1 \
    run_nix_gc_with_wait_progress 7d 2>&1)"
  _rc=$?
  _elapsed=$(($(date +%s) - _t0))
  _pid="$(cat "$_stub_dir/pid" 2>/dev/null || true)"

  if [ "$_rc" -eq 1 ]; then
    assert_pass "expired run exits 1"
  else
    assert_fail "expired run exits 1" "rc=$_rc output=$_out"
  fi
  assert_elapsed_below "expiry is enforced near the deadline" 20 "$_elapsed" 60
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
  elif [ -z "$_pid" ]; then
    assert_fail "the child is killed and reaped" "the stub never recorded its pid"
  else
    assert_fail "the child is killed and reaped" "pid=$_pid still alive"
  fi
}

_case_deadline_fires_before_the_child_speaks() {
  local _content
  # WHY truncate: every case shares one stub dir, so a stale pid from the
  # previous victim would make this pass for the wrong reason. Truncating needs
  # no deletion transport, unlike removing the file.
  : >"$_stub_dir/pid"
  STUB_START_DELAY=3 STUB_SLEEP=60 \
    NUCLEUS_GC_LOCK_WAIT_DEADLINE=5 NUCLEUS_GC_LOCK_WAIT_PROGRESS_INTERVAL=1 \
    run_nix_gc_with_wait_progress 7d >/dev/null 2>&1
  _content="$(cat "$_stub_dir/pid" 2>/dev/null || true)"

  if [ -n "$_content" ] && ! kill -0 "$_content" 2>/dev/null; then
    assert_pass "a silent child is reaped"
  elif [ -z "$_content" ]; then
    assert_fail "a silent child is reaped" "the stub never recorded its pid"
  else
    assert_fail "a silent child is reaped" "pid=$_content still alive"
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
  if [ "$_rc" -eq 0 ]; then
    assert_pass "zero deadline runs to completion"
  else
    assert_fail "zero deadline runs to completion" "rc=$_rc elapsed=${_elapsed}s output=$_out"
  fi
  assert_elapsed_at_least "a zero deadline actually waits for the work" 3 "$_elapsed"
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
_case_deadline_fires_before_the_child_speaks
_case_success_passes_output_through
_case_zero_deadline_disables_the_bound
_case_invalid_deadline_falls_back_to_the_default

finish_tests
