#!/usr/bin/env bash
# Tests that test output format matches current expected patterns.
# Asserts against framework-lib.sh (not test.sh) since format logic
# moved to the shared framework library.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Path to framework-lib.sh relative to repo root
# shellcheck source=../../scripts/framework-lib.sh
FRAMEWORK_LIB="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)/scripts/framework-lib.sh"

test_total_steps_variable() {
    if grep -qF '_total_steps' "$FRAMEWORK_LIB"; then
        assert_pass "_total_steps variable present"
    else
        assert_fail "_total_steps variable" "Expected _total_steps= not found"
    fi
}

test_failed_steps_variable() {
    if grep -qF '_failed_steps' "$FRAMEWORK_LIB"; then
        assert_pass "_failed_steps variable present"
    else
        assert_fail "_failed_steps variable" "Expected _failed_steps= not found"
    fi
}

test_combined_status_table() {
    if grep -qF "printf '  step %2d  ✓  %5d ms" "$FRAMEWORK_LIB"; then
        assert_pass "Combined status table present"
    else
        assert_fail "Combined status table" "Expected combined printf format not found"
    fi
}

test_total_timing_line() {
    if grep -qF "printf '  total:   %5d ms" "$FRAMEWORK_LIB"; then
        assert_pass "Total timing line present"
    else
        assert_fail "Total timing line" "Expected printf format for total timing not found"
    fi
}

test_generic_failure_message() {
    if grep -qF "some checks failed" "$FRAMEWORK_LIB"; then
        assert_pass "Generic failure message present"
    else
        assert_fail "Generic failure message" "Expected 'some checks failed' pattern not found"
    fi
}

test_success_message() {
    if grep -qF "all checks passed." "$FRAMEWORK_LIB"; then
        assert_pass "Success message present"
    else
        assert_fail "Success message" "Expected 'all checks passed.' pattern not found"
    fi
}

test_explicit_failure_summary() {
    if grep -qF "Failed steps" "$FRAMEWORK_LIB"; then
        assert_pass "Explicit failure summary present"
    else
        assert_fail "Explicit failure summary" "Expected 'Failed steps' pattern not found"
    fi
}

test_aggregate_results() {
    if grep -qF "aggregate_results()" "$FRAMEWORK_LIB"; then
        assert_pass "aggregate_results function defined"
    else
        assert_fail "aggregate_results" "Expected aggregate_results() function not found"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing test output format via framework-lib.sh..."
echo ""

test_total_steps_variable
test_failed_steps_variable
test_combined_status_table
test_total_timing_line
test_generic_failure_message
test_success_message
test_explicit_failure_summary
test_aggregate_results

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
