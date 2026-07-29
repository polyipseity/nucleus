#!/usr/bin/env bash
# Tests that check output format matches current expected patterns.
# Asserts against framework-lib.sh (not check.sh) since format logic
# moved to the shared framework library.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Path to framework-lib.sh relative to repo root
# shellcheck source=../../scripts/framework-lib.sh
FRAMEWORK_LIB="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)/scripts/framework-lib.sh"

test_combined_status_table() {
    if grep -qF "_total_steps" "$FRAMEWORK_LIB"; then
        assert_pass "_total_steps variable present"
    else
        assert_fail "_total_steps variable" "Expected '_total_steps' variable not found"
    fi
    if grep -qF "_failed_steps" "$FRAMEWORK_LIB"; then
        assert_pass "_failed_steps variable present"
    else
        assert_fail "_failed_steps variable" "Expected '_failed_steps' variable not found"
    fi
}

test_total_timing_line() {
    if grep -qF "printf '  total:   %5d ms" "$FRAMEWORK_LIB"; then
        assert_pass "Total timing line uses printf format"
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

test_generic_success_message() {
    if grep -qF "all checks passed." "$FRAMEWORK_LIB"; then
        assert_pass "Generic success message present"
    else
        assert_fail "Generic success message" "Expected 'all checks passed.' pattern not found"
    fi
}

test_explicit_failure_summary() {
    if grep -qF "Failed steps:" "$FRAMEWORK_LIB"; then
        assert_pass "Explicit failure summary present"
    else
        assert_fail "Explicit failure summary" "Expected 'Failed steps:' not found"
    fi
}

test_run_step_wrapper() {
    if grep -qF "_run_step()" "$FRAMEWORK_LIB"; then
        assert_pass "_run_step wrapper defined"
    else
        assert_fail "_run_step wrapper" "Expected _run_step() function not found"
    fi
}

test_register_step() {
    if grep -qF "register_step()" "$FRAMEWORK_LIB"; then
        assert_pass "register_step function defined"
    else
        assert_fail "register_step" "Expected register_step() function not found"
    fi
}

test_parse_args() {
    if grep -qF "parse_args()" "$FRAMEWORK_LIB"; then
        assert_pass "parse_args function defined"
    else
        assert_fail "parse_args" "Expected parse_args() function not found"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing check output format via framework-lib.sh..."
echo ""

test_combined_status_table
test_total_timing_line
test_generic_failure_message
test_generic_success_message
test_explicit_failure_summary
test_run_step_wrapper
test_register_step
test_parse_args

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
