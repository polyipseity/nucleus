#!/usr/bin/env bash
# Tests for gitignore-aware deny-list library functions.
#
# Tests filter_gitignored() with known gitignored patterns, tracked files,
# batch filtering, empty input, nested .gitignore, and no-git-directory
# fallback.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
NUCLEUS_REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/deny-list.sh
. "$NUCLEUS_REPO_ROOT/src/scripts/lib/deny-list.sh"

# Helper: run filter_gitignored with input lines and capture output.
_filter_test() {
  printf '%s\n' "$@" | filter_gitignored
}

# Test 1: filter_gitignored with a known ignored path (result/ is in .gitignore)
test_filter_ignored_path() {
  local result
  result=$(echo "result" | filter_gitignored) || true
  if [[ -z "$result" ]]; then
    assert_pass "filter_gitignored: known-ignored path 'result' is filtered out"
  else
    assert_fail "filter_gitignored: known-ignored path 'result' is filtered out" "Expected empty, got: $result"
  fi
}

# Test 2: filter_gitignored with a known tracked path (this test file itself)
test_filter_tracked_path() {
  local input="${NUCLEUS_REPO_ROOT}/tests/scripts/deny-list-tests.sh"
  local result
  result=$(echo "$input" | filter_gitignored) || true
  if [[ "$result" == "$input" ]]; then
    assert_pass "filter_gitignored: known-tracked path passes through"
  else
    assert_fail "filter_gitignored: known-tracked path passes through" "Expected '$input', got: '$result'"
  fi
}

# Test 3: batch filtering with mix of ignored and non-ignored paths
test_filter_batch_mixed() {
  local tracked="${NUCLEUS_REPO_ROOT}/README.md"
  local result
  result=$(printf '%s\n' "result" "$tracked" ".direnv/cache" | filter_gitignored) || true
  if [[ "$result" == "$tracked" ]]; then
    assert_pass "filter_gitignored: batch filtering keeps tracked, removes ignored"
  else
    assert_fail "filter_gitignored: batch filtering keeps tracked, removes ignored" "Expected '$tracked', got: '$result'"
  fi
}

# Test 4: filter_gitignored with empty input produces empty output
test_filter_empty_input() {
  local result
  result=$(echo "" | filter_gitignored) || true
  if [[ -z "$result" ]]; then
    assert_pass "filter_gitignored: empty input produces empty output"
  else
    assert_fail "filter_gitignored: empty input produces empty output" "Expected empty, got: '$result'"
  fi
}

# Test 5: filter_gitignored with nested .gitignore patterns (result-*)
test_filter_glob_ignored() {
  local result
  result=$(echo "result-abc" | filter_gitignored) || true
  if [[ -z "$result" ]]; then
    assert_pass "filter_gitignored: glob pattern 'result-*' is filtered out"
  else
    assert_fail "filter_gitignored: glob pattern 'result-*' is filtered out" "Expected empty, got: $result"
  fi
}

# Test 6: filter_gitignored with an ignored path prefix inside a subdirectory
test_filter_subdir_ignored() {
  local result
  result=$(echo "some/dir/result" | filter_gitignored) || true
  if [[ -z "$result" ]]; then
    assert_pass "filter_gitignored: 'result' ignored in subdirectories too"
  else
    assert_fail "filter_gitignored: 'result' ignored in subdirectories too" "Expected empty, got: $result"
  fi
}

# Test 7: filter_gitignored survives `set -e` when nothing is ignored.
# Regression for the cache_file_lists bug: `git check-ignore` exits 1 when
# no path is ignored, and `set -e` used to abort the subshell before the
# exit code was captured, yielding empty CACHED_* arrays in full check mode.
test_filter_no_ignore_under_errexit() {
  local input="${NUCLEUS_REPO_ROOT}/tests/scripts/deny-list-tests.sh"
  local result
  # `set -euo pipefail` + process substitution mirrors cache_file_lists
  # (step-runner.sh); must pass the tracked input through unchanged.
  result=$(
    set -euo pipefail
    printf '%s\n' "$input" | filter_gitignored
  ) || true
  if [[ "$result" == "$input" ]]; then
    assert_pass "filter_gitignored: no-ignore input passes through under set -e"
  else
    assert_fail "filter_gitignored: no-ignore input passes through under set -e" "Expected '$input', got: '$result'"
  fi
}

echo ""
echo "Deny-list library tests"
echo "======================="
echo ""
test_filter_ignored_path
test_filter_tracked_path
test_filter_batch_mixed
test_filter_empty_input
test_filter_glob_ignored
test_filter_subdir_ignored
test_filter_no_ignore_under_errexit

echo ""
echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
