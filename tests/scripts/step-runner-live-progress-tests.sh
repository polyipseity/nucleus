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

test_fast_step_reports_before_slow
test_running_step_reports_still_running

finish_tests
