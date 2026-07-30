#!/usr/bin/env bash
# Unit tests for step-runner.sh functions in isolation.
# Tests NEW behavior per Spec A (step IDs) and Spec B (--skip-steps).
# These tests will fail (TDD red phase) until the framework is updated.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Spec A: Step ID registration (new 4-arg form) ----
# Tests will fail until step-runner.sh supports 4-arg register_step.

test_register_step_with_id() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        register_step "code-formatting" 1 "Code formatting" test_func
        echo "${_STEP_IDS[0]} ${_STEP_NUMBERS[0]} ${_STEP_NAMES[0]}"
    )
    if echo "$result" | grep -q "code-formatting 1 Code formatting"; then
        assert_pass "register_step stores id, number, name correctly"
    else
        assert_fail "register_step 4-arg" "Expected 'code-formatting 1 Code formatting', got: $result"
    fi
}

test_register_step_multiple_with_ids() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        register_step "one" 1 "One" f1
        register_step "two" 2 "Two" f2
        register_step "three" 3 "Three" f3
        echo "${_STEP_IDS[*]} ${#_STEP_NUMBERS[@]}"
    )
    if echo "$result" | grep -q "one two three 3"; then
        assert_pass "register_step accumulates multiple steps with IDs"
    else
        assert_fail "register_step multiple IDs" "Expected 'one two three 3', got: $result"
    fi
}

test_register_step_id_with_digits_errors() {
    local exit_code=0
    # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "test-1-bad" 1 "Bad" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "register_step with digit in ID errors (Spec A)"
    else
        assert_fail "register_step digit ID" "Expected non-zero exit for ID containing digit, got: $exit_code"
    fi
}

test_register_step_empty_id_errors() {
    local exit_code=0
    # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "" 1 "Empty" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "register_step with empty ID errors (Spec A)"
    else
        assert_fail "register_step empty ID" "Expected non-zero exit for empty ID, got: $exit_code"
    fi
}

test_register_step_duplicate_id_errors() {
    local exit_code=0
    # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "dup" 1 "First" true
        register_step "dup" 2 "Second" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "register_step duplicate ID errors (Spec A)"
    else
        assert_fail "register_step dup ID" "Expected non-zero exit for duplicate ID, got: $exit_code"
    fi
}

test_register_step_duplicate_number_errors() {
    local exit_code=0
    # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        register_step "first" 1 "First" true
        register_step "second" 1 "Second" true 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "register_step duplicate number errors (Spec A)"
    else
        assert_fail "register_step dup num" "Expected non-zero exit for duplicate number, got: $exit_code"
    fi
}

# ---- Spec B: --skip-steps flag ----
# Tests will fail until parse_args supports --skip-steps.

test_skip_steps_equals_form() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps=a,b"
        echo "${SKIP_STEPS[*]}"
    )
    if echo "$result" | grep -q "a b"; then
        assert_pass "--skip-steps=a,b populates SKIP_STEPS with two entries"
    else
        assert_fail "--skip-steps equals" "Expected 'a b', got: $result"
    fi
}

test_skip_steps_empty_value() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps="
        echo "${#SKIP_STEPS[@]}"
    )
    if [ "$result" = "0" ]; then
        assert_pass "--skip-steps= results in empty SKIP_STEPS"
    else
        assert_fail "--skip-steps empty" "Expected 0 entries, got: $result"
    fi
}

test_skip_steps_unknown_id_no_error() {
    local exit_code=0
    # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps=nonexistent-id"
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        assert_pass "--skip-steps with unknown ID does not error (Spec B)"
    else
        assert_fail "--skip-steps unknown" "Expected exit 0 for unknown ID, got: $exit_code"
    fi
}

test_skip_steps_dedup() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps=a,a"
        echo "${SKIP_STEPS[*]} ${#SKIP_STEPS[@]}"
    )
    if echo "$result" | grep -q "a 1"; then
        assert_pass "--skip-steps=a,a deduplicates to one entry"
    else
        assert_fail "--skip-steps dedup" "Expected 'a 1', got: $result"
    fi
}

test_skip_steps_last_value_wins() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "--skip-steps=a" "--skip-steps=b"
        echo "${SKIP_STEPS[*]}"
    )
    if echo "$result" | grep -q "b" && ! echo "$result" | grep -q "a"; then
        assert_pass "--skip-steps last value wins (no accumulation)"
    else
        assert_fail "--skip-steps last-win" "Expected 'b' only, got: $result"
    fi
}

# ---- Legacy behavior that must be preserved ----
# Some existing tests from pre-Phase-1, adapted for new signature where needed.

test_parse_args_help() {
    local exit_code
    exit_code=0
    # shellcheck disable=SC2097,SC2098,SC2031 # reason: intentional export to bash -c subprocess
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { echo "usage: test"; }
        parse_args --help
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 1 ]; then
        assert_fail "parse_args --help" "Unexpected exit code: $exit_code"
    else
        assert_pass "parse_args --help exits cleanly"
    fi
}

test_parse_args_scoped() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --scoped
        echo "$SCOPED $HAS_ARGS"
    )
    if [ "$result" = "true true" ]; then
        assert_pass "parse_args --scoped sets SCOPED=true and HAS_ARGS=true"
    else
        assert_fail "parse_args --scoped" "Expected 'true true', got: $result"
    fi
}

test_parse_args_positions() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --fail-fast path/to/file.nix
        echo "$HAS_ARGS ${POSITIONAL_ARGS[*]}"
    )
    if echo "$result" | grep -q "true.*path/to/file.nix"; then
        assert_pass "parse_args captures positional args"
    else
        assert_fail "parse_args positions" "Expected 'true ...file.nix', got: $result"
    fi
}

test_aggregate_results_parses_exit_files() {
    local result
    result=$(
        # shellcheck disable=SC2030,SC2031 # reason: REPO_ROOT inherited
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        say() { echo "say: $*"; }
        error() { echo "error: $*" >&2; }
        _wave_init
        register_step "test" 1 "Test" test_func
        printf '%s' "0" > "$_wave_tmpdir/step-1.exit"
        printf '%s' "42" > "$_wave_tmpdir/step-1.time"
        printf '%s' "Test" > "$_wave_tmpdir/step-1.name"
        # shellcheck disable=SC2317 # reason: aggregate_results calls exit, captured in subshell
        aggregate_results 2>&1 || true
    ) 2>&1
    if echo "$result" | grep -q "say: all checks passed."; then
        assert_pass "aggregate_results parses exit files correctly"
    else
        assert_fail "aggregate_results" "Expected 'all checks passed'. Got: $result"
    fi
}

# ---- Run tests ----
echo ""
echo "=== Phase 1: Framework core unit tests (POSIX) ==="
echo "Tests for Spec A (step IDs) and Spec B (--skip-steps)."
echo "These will FAIL (red phase) until step-runner.sh is updated."
echo ""

test_register_step_with_id
test_register_step_multiple_with_ids
test_register_step_id_with_digits_errors
test_register_step_empty_id_errors
test_register_step_duplicate_id_errors
test_register_step_duplicate_number_errors
test_skip_steps_equals_form
test_skip_steps_empty_value
test_skip_steps_unknown_id_no_error
test_skip_steps_dedup
test_skip_steps_last_value_wins

echo "--- Legacy behavior tests ---"
test_parse_args_help
test_parse_args_scoped
test_parse_args_positions
test_aggregate_results_parses_exit_files

echo ""
echo "--- Phase 1 POSIX unit tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
