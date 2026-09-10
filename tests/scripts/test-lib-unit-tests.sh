#!/usr/bin/env bash
# Unit tests for test-lib.sh (--skip-system-build removal and flag parsing).
#
# Verifies --skip-system-build is removed and step 04 runs without it.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Spec D: --skip-system-build removal ----

# After removal, --skip-system-build must be rejected (unknown flag -> exit 1).
test_parse_args_skip_system_build_removed() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
        parse_args --skip-system-build 2>/dev/null || true
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "test-lib parse_args rejects --skip-system-build after removal"
  else
    assert_fail "tdd-ssb-reject" "Expected exit != 0 from --skip-system-build, got: $exit_code"
  fi
}

# Unknown flags must still error.
test_parse_args_no_unrecognized_flags() {
  local exit_code=0
  bash -c '
        . "'"$REPO_ROOT"'/src/scripts/tests/test-lib.sh"
        parse_args --nonexistent-flag-x99 2>/dev/null || true
    ' 2>/dev/null || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    assert_pass "test-lib parse_args rejects unknown flags"
  else
    assert_fail "tdd-unknown-flag" "Expected exit != 0 from unknown flag, got: $exit_code"
  fi
}

# Usage must not mention --skip-system-build after removal.
test_test_lib_usage_no_skip_system_build() {
  local result
  result=$(
    . "$REPO_ROOT/src/scripts/tests/test-lib.sh"
    usage 2>&1 || true
  )
  if ! echo "$result" | grep -q 'skip-system-build'; then
    assert_pass "usage() does not mention --skip-system-build after removal"
  else
    assert_fail "tdd-usage-no-ssb" "usage() still mentions --skip-system-build: $(echo "$result" | grep 'skip-system-build')"
  fi
}

# Every suite that sources this library must be able to fail: assertions only bump
# a counter, so a suite that never turns the tally into an exit status reports
# success to the runner no matter what it asserted.
test_all_consumers_end_with_finish_tests() {
  # Derived here rather than reusing SCRIPT_DIR/REPO_ROOT: sourcing
  # src/scripts/tests/test-lib.sh below reassigns both, so shellcheck reads them
  # as subshell-modified (SC2031) at every use outside a subshell.
  local _dir
  _dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local _file _last _missing=""
  # Two levels cover the suite directory and its subdirectories; an unmatched glob
  # stays literal, so the -f guard skips it.
  for _file in "$_dir"/*-tests.sh "$_dir"/*/*-tests.sh; do
    [ -f "$_file" ] || continue
    grep -qE '^[[:space:]]*\.[[:space:]].*test-lib\.sh' "$_file" || continue
    _last="$(awk 'NF && $1 !~ /^#/ { last = $0 } END { sub(/^[[:space:]]+/, "", last); print last }' "$_file")"
    [ "$_last" = "finish_tests" ] || _missing="$_missing $(basename "$_file")"
  done
  if [ -z "$_missing" ]; then
    assert_pass "every test-lib.sh consumer ends with finish_tests"
  else
    assert_fail "every test-lib.sh consumer ends with finish_tests" "not ending with finish_tests:$_missing"
  fi
}

# ---- Run tests ----
section 1 "Phase 2: test-lib unit tests"
echo ""

test_parse_args_skip_system_build_removed
test_parse_args_no_unrecognized_flags
test_test_lib_usage_no_skip_system_build
test_all_consumers_end_with_finish_tests

finish_tests
