#!/usr/bin/env bash
# Tests that test.sh output format matches expected patterns (Phase 6a: combined status table).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Path to test.sh relative to repo root
# shellcheck source=../../scripts/test.sh
TEST_SH="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)/scripts/test.sh"

# ---- Phase 6a format features ----

test_total_steps_variable() {
    if grep -qF '_total_steps=' "$TEST_SH"; then
        assert_pass "_total_steps variable present"
    else
        assert_fail "_total_steps variable" "Expected _total_steps= not found"
    fi
}

test_failed_steps_variable() {
    if grep -qF '_failed_steps=' "$TEST_SH"; then
        assert_pass "_failed_steps variable present"
    else
        assert_fail "_failed_steps variable" "Expected _failed_steps= not found"
    fi
}

test_combined_status_table() {
    # Combined format with status icons: printf '  step %2d  %s  %5d ms  %s\n'
    # test.sh hardcodes ✓/✗/— in the format string, one variant per branch.
    if grep -qF "printf '  step %2d  ✓  %5d ms" "$TEST_SH"; then
        assert_pass "Combined status table present"
    else
        assert_fail "Combined status table" "Expected combined printf format not found"
    fi
}

test_total_timing_line() {
    if grep -qF "printf '  total:   %5d ms" "$TEST_SH"; then
        assert_pass "Total timing line present"
    else
        assert_fail "Total timing line" "Expected printf format for total timing not found"
    fi
}

test_generic_failure_message() {
    if grep -qF "some tests failed" "$TEST_SH"; then
        assert_pass "Generic failure message present"
    else
        assert_fail "Generic failure message" "Expected 'some tests failed' pattern not found"
    fi
}

test_success_message() {
    if grep -qF "all tests passed." "$TEST_SH"; then
        assert_pass "Success message present"
    else
        assert_fail "Success message" "Expected 'all tests passed.' pattern not found"
    fi
}

test_explicit_failure_summary() {
    if grep -qF "Failed steps" "$TEST_SH"; then
        assert_pass "Explicit failure summary present"
    else
        assert_fail "Explicit failure summary" "Expected 'Failed steps' pattern not found"
    fi
}

test_step_name_files() {
    # shellcheck disable=SC2016 # reason: literal $ in grep pattern to match step-$_step.name in source
    if grep -qF 'step-$_step.name' "$TEST_SH"; then
        assert_pass "Step name file writes present"
    else
        assert_fail "Step name files" "Expected step name file writes not found"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing test.sh output format (Phase 6a: combined status table)..."
echo ""

test_total_steps_variable
test_failed_steps_variable
test_combined_status_table
test_total_timing_line
test_generic_failure_message
test_success_message
test_explicit_failure_summary
test_step_name_files

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
