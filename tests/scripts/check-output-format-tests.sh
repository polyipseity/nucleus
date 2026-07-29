#!/usr/bin/env bash
# Tests that check.sh output format matches current expected patterns.
# This is the "red" phase — assertions match the pre-change format.
# When check.sh is refactored (Phases 1-4), update assertions accordingly.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Path to check.sh relative to repo root (this script runs from tests/scripts/)
# shellcheck source=../../scripts/check.sh
CHECK_SH="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)/scripts/check.sh"

# ---- Phase 1 invariants ----
# Combined status+timing table replaces timing-only table.

test_combined_status_table() {
    # Combined table: '  step %2d  %s  %5d ms  %s\n' with status icon and name
    if grep -qF "_total_steps" "$CHECK_SH"; then
        assert_pass "_total_steps variable present"
    else
        assert_fail "_total_steps variable" "Expected '_total_steps' variable not found"
    fi
    if grep -qF "_failed_steps" "$CHECK_SH"; then
        assert_pass "_failed_steps variable present"
    else
        assert_fail "_failed_steps variable" "Expected '_failed_steps' variable not found"
    fi
}

test_total_timing_line() {
    # Total line uses printf with total ms
    if grep -qF "printf '  total:   %5d ms" "$CHECK_SH"; then
        assert_pass "Total timing line uses printf format"
    else
        assert_fail "Total timing line" "Expected printf format for total timing not found"
    fi
}

test_generic_failure_message() {
    # Generic failure: "some checks failed with exit code"
    if grep -qF "some checks failed" "$CHECK_SH"; then
        assert_pass "Generic failure message present"
    else
        assert_fail "Generic failure message" "Expected 'some checks failed' pattern not found"
    fi
}

test_generic_success_message() {
    # Generic success: "all checks passed."
    if grep -qF "all checks passed." "$CHECK_SH"; then
        assert_pass "Generic success message present"
    else
        assert_fail "Generic success message" "Expected 'all checks passed.' pattern not found"
    fi
}

test_step_prefix_present() {
    # Phase 2 adds [Step N] prefix via _step_prefix variable
    if grep -qF "_step_prefix" "$CHECK_SH"; then
        assert_pass "[Step N] prefix support added (Phase 2)"
    else
        assert_fail "[Step N] prefix" "Expected _step_prefix variable not found"
    fi
}

test_no_explicit_failure_summary() {
    # Phase 3 does not add explicit failure summary yet
    if grep -qF "Failed step" "$CHECK_SH"; then
        assert_fail "Explicit failure summary" "Phase 3 should NOT have explicit failure summary yet"
    else
        assert_pass "No explicit failure summary (Phase 3)"
    fi
}

test_test_boundary_markers() {
    # Phase 3: test-runner boundary markers present
    if grep -qF -- "--- test output ---" "$CHECK_SH" && grep -qF -- "--- end test output ---" "$CHECK_SH"; then
        assert_pass "Test boundary markers present (Phase 3)"
    else
        assert_fail "Test boundary markers" "Expected '--- test output ---' and '--- end test output ---' markers"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing check.sh output format (Phase 3: test-runner boundaries)..."
echo ""

test_combined_status_table
test_total_timing_line
test_generic_failure_message
test_generic_success_message
test_step_prefix_present
test_test_boundary_markers
test_no_explicit_failure_summary

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
