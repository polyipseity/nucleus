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

# ---- Run tests ----
echo ""
echo "=== Phase 2: test-lib unit tests ==="
echo ""

test_parse_args_skip_system_build_removed
test_parse_args_no_unrecognized_flags
test_test_lib_usage_no_skip_system_build

echo ""
echo "--- Phase 2 test-lib unit tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
