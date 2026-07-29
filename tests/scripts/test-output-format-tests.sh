#!/usr/bin/env bash
# Tests that test.sh output format matches current expected patterns.
# This is the "red" phase — assertions match the pre-change format.
# When test.sh is refactored (Phase 6a), update assertions accordingly.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Path to test.sh relative to repo root
# shellcheck source=../../scripts/test.sh
TEST_SH="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)/scripts/test.sh"

# ---- Phase 0 invariants ----
# These match the current (pre-refactor) format.

test_timing_table_format() {
    # Timing entries use printf with step number and ms.
    # Pattern: printf '  step %2d: %5d ms\n'  (note: \n is literal backslash-n)
    if grep -qF "printf '  step %2d: %5d ms" "$TEST_SH"; then
        assert_pass "Timing table uses printf format: step %2d, %5d ms"
    else
        assert_fail "Timing table format" "Expected printf format for step timing not found"
    fi
}

test_total_timing_line() {
    # Total line uses printf with total ms
    if grep -qF "printf '  total:   %5d ms" "$TEST_SH"; then
        assert_pass "Total timing line uses printf format"
    else
        assert_fail "Total timing line" "Expected printf format for total timing not found"
    fi
}

test_generic_failure_message() {
    # Generic failure: "some tests failed with exit code"
    if grep -qF "some tests failed" "$TEST_SH"; then
        assert_pass "Generic failure message present"
    else
        assert_fail "Generic failure message" "Expected 'some tests failed' pattern not found"
    fi
}

test_generic_success_message() {
    # Generic success: "all tests passed."
    if grep -qF "all tests passed." "$TEST_SH"; then
        assert_pass "Generic success message present"
    else
        assert_fail "Generic success message" "Expected 'all tests passed.' pattern not found"
    fi
}

test_no_combined_status_table() {
    # Pre-refactor: no combined status indicator in timing table output.
    if grep -q '^\s\+step .* [✓✗]' "$TEST_SH"; then
        assert_fail "Combined status table" "Pre-refactor should NOT have inline status indicators"
    else
        assert_pass "No combined status table (pre-refactor)"
    fi
}

test_no_step_prefix() {
    # Pre-refactor: no [Step N] prefix in section headers
    if grep -qF "[Step " "$TEST_SH"; then
        assert_fail "Step N prefix" "Pre-refactor should NOT have [Step N] prefix"
    else
        assert_pass "No [Step N] prefix (pre-refactor)"
    fi
}

test_no_test_boundary_markers() {
    # Pre-refactor: no "--- test output ---" boundaries
    if grep -qF -- "--- test output ---" "$TEST_SH"; then
        assert_fail "Test boundary markers" "Pre-refactor should NOT have test output boundaries"
    else
        assert_pass "No test boundary markers (pre-refactor)"
    fi
}

test_no_explicit_failure_summary() {
    # Pre-refactor: no "Failed steps:" or similar failure summary
    if grep -qF "Failed step" "$TEST_SH"; then
        assert_fail "Explicit failure summary" "Pre-refactor should NOT have explicit failure summary"
    else
        assert_pass "No explicit failure summary (pre-refactor)"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing test.sh output format (pre-refactor pattern)..."
echo ""

test_timing_table_format
test_total_timing_line
test_generic_failure_message
test_generic_success_message
test_no_combined_status_table
test_no_step_prefix
test_no_test_boundary_markers
test_no_explicit_failure_summary

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
