#!/usr/bin/env bash
# Tests for live step progress reporting in step-runner.sh (Task 2).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT

_t_fast() { :; }
_t_slow() { sleep 3; }
_t_hang() { sleep 30; }

test_fast_step_reports_before_slow() {
  local _out
  _out="$(
    export PARALLEL_JOBS=2 NUCLEUS_STEP_PROGRESS_INTERVAL=1
    export HAS_ARGS=false FAIL_FAST=false ONLINE=false
    # shellcheck source=../../src/scripts/lib/step-runner.sh
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _nuc_c1_dim="" _nuc_c1_reset="" _nuc_c1_bold="" _nuc_c1_cyan=""
    _nuc_c2_dim="" _nuc_c2_reset=""
    cache_file_lists() { :; }
    register_step "fast" 5 "Fast" _t_fast
    register_step "slow" 6 "Slow" _t_slow
    run_all_steps
  )"
  local _fast _slow
  _fast="$(printf '%s\n' "$_out" | grep -n 'step 5 finished' | head -1 | cut -d: -f1)"
  _slow="$(printf '%s\n' "$_out" | grep -n 'step 6 finished' | head -1 | cut -d: -f1)"
  if [ -n "$_fast" ] && [ -n "$_slow" ] && [ "$_fast" -lt "$_slow" ]; then
    assert_pass "the faster step is reported before the slower one finishes"
  else
    assert_fail "the faster step is reported before the slower one finishes" "got: $_out"
  fi
}

test_running_step_reports_still_running() {
  local _out
  _out="$(
    export PARALLEL_JOBS=2 NUCLEUS_STEP_PROGRESS_INTERVAL=1
    export HAS_ARGS=false FAIL_FAST=false ONLINE=false
    # shellcheck source=../../src/scripts/lib/step-runner.sh
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _nuc_c1_dim="" _nuc_c1_reset="" _nuc_c1_bold="" _nuc_c1_cyan=""
    _nuc_c2_dim="" _nuc_c2_reset=""
    cache_file_lists() { :; }
    register_step "fast" 5 "Fast" _t_fast
    register_step "slow" 6 "Slow" _t_slow
    run_all_steps
  )"
  if printf '%s\n' "$_out" | grep -q 'step 6 still running'; then
    assert_pass "a running step is reported while it is still running"
  else
    assert_fail "a running step is reported while it is still running" "got: $_out"
  fi
}

test_step_over_the_bound_fails_with_124() {
  local _start _elapsed _out
  _start=$SECONDS
  _out="$(
    export PARALLEL_JOBS=1 NUCLEUS_STEP_TIMEOUT=2 NUCLEUS_STEP_PROGRESS_INTERVAL=0
    export HAS_ARGS=false FAIL_FAST=false ONLINE=false
    # shellcheck source=../../src/scripts/lib/step-runner.sh
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _nuc_c1_dim="" _nuc_c1_reset="" _nuc_c1_bold="" _nuc_c1_cyan=""
    _nuc_c2_dim="" _nuc_c2_reset=""
    cache_file_lists() { :; }
    register_step "hang" 5 "Hang" _t_hang
    run_all_steps
    printf 'exitfile=%s\n' "$(cat "$_wave_tmpdir/step-5.exit" 2>/dev/null || true)"
  )"
  _elapsed=$((SECONDS - _start))
  if printf '%s\n' "$_out" | grep -q 'exitfile=124'; then
    assert_pass "a step past the bound exits 124"
  else
    assert_fail "a step past the bound exits 124" "got: $_out"
  fi
  case "$_elapsed" in
  0|1|2|3|4|5)
    assert_pass "the bound is enforced in seconds not minutes"
    ;;
  *)
    assert_fail "the bound is enforced in seconds not minutes" "took ${_elapsed}s"
    ;;
  esac
  if printf '%s\n' "$_out" | grep -q 'exceeded NUCLEUS_STEP_TIMEOUT=2s'; then
    assert_pass "the step's captured output names the bound"
  else
    assert_fail "the step's captured output names the bound" "got: $_out"
  fi
}

test_step_timeout_rejects_non_numeric() {
  local _out _rc
  _out="$(
    export PARALLEL_JOBS=1 NUCLEUS_STEP_TIMEOUT=abc NUCLEUS_STEP_PROGRESS_INTERVAL=0
    export HAS_ARGS=false FAIL_FAST=false ONLINE=false
    # shellcheck source=../../src/scripts/lib/step-runner.sh
    . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
    _nuc_c1_dim="" _nuc_c1_reset="" _nuc_c1_bold="" _nuc_c1_cyan=""
    _nuc_c2_dim="" _nuc_c2_reset=""
    cache_file_lists() { :; }
    register_step "fast" 5 "Fast" _t_fast
    run_all_steps 2>&1
  )" && _rc=0 || _rc=$?
  if [ "$_rc" -eq 2 ]; then
    assert_pass "non-numeric NUCLEUS_STEP_TIMEOUT is a hard error"
  else
    assert_fail "non-numeric NUCLEUS_STEP_TIMEOUT is a hard error" "rc=$_rc out=$_out"
  fi
  if printf '%s\n' "$_out" | grep -q 'NUCLEUS_STEP_TIMEOUT must be whole seconds'; then
    assert_pass "non-numeric NUCLEUS_STEP_TIMEOUT names the variable"
  else
    assert_fail "non-numeric NUCLEUS_STEP_TIMEOUT names the variable" "got: $_out"
  fi
}

test_fast_step_reports_before_slow
test_running_step_reports_still_running
test_step_over_the_bound_fails_with_124
test_step_timeout_rejects_non_numeric

finish_tests
