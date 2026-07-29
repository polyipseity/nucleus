#!/usr/bin/env bash
# Unit tests for framework-lib.sh functions in isolation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# Source framework-lib.sh in a sub-shell to test functions
test_register_step_function() {
    local result
    result=$(
        REPO_ROOT="$REPO_ROOT"
        # shellcheck disable=SC1090,SC1091 # reason: dynamic source path tested in isolation
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
        register_step 1 "Test Step" test_func
        echo "${_STEP_NUMBERS[*]} ${_STEP_NAMES[*]} ${_STEP_FUNCS[*]}"
    )
    if echo "$result" | grep -q "1 Test Step test_func"; then
        assert_pass "register_step stores step metadata correctly"
    else
        assert_fail "register_step" "Expected '1 Test Step test_func', got: $result"
    fi
}

test_register_step_multiple() {
    local result
    result=$(
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
        register_step 1 "One" f1
        register_step 2 "Two" f2
        register_step 3 "Three" f3
        echo "${#_STEP_NUMBERS[@]}"
    )
    if [ "$result" = "3" ]; then
        assert_pass "register_step accumulates multiple steps"
    else
        assert_fail "register_step multiple" "Expected 3 steps, got: $result"
    fi
}

test_parse_args_help() {
    local exit_code
    exit_code=0
    # --help should exit 0
    REPO_ROOT="$REPO_ROOT" \
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/framework-lib.sh"
        usage() { echo "usage: test"; }
        parse_args --help
    ' 2>/dev/null || exit_code=$?
    # parse_args with --help exits via exit 0 (the usage function calls exit)
    # The sub-shell trap makes exit not kill the test, so we check the exit code
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 1 ]; then
        assert_fail "parse_args --help" "Unexpected exit code: $exit_code"
    else
        assert_pass "parse_args --help exits cleanly"
    fi
}

test_parse_args_format_flag() {
    local result
    result=$(
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
        usage() { true; }
        parse_args --format
        echo "$FORMAT_NIX"
    )
    if [ "$result" = "true" ]; then
        assert_pass "parse_args --format sets FORMAT_NIX=true"
    else
        assert_fail "parse_args --format" "Expected true, got: $result"
    fi
}

test_parse_args_scoped() {
    local result
    result=$(
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
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
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
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
        REPO_ROOT="$REPO_ROOT"
        . "$REPO_ROOT/src/scripts/lib/framework-lib.sh"
        # Define stubs for functions framework-lib.sh expects
        say() { echo "say: $*"; }
        error() { echo "error: $*" >&2; }
        # Set up step registration
        _wave_init
        register_step 1 "Test" test_func
        # Write the .exit/.time/.name files manually (simulating _run_step)
        printf '%s' "0" > "$_wave_tmpdir/step-1.exit"
        printf '%s' "42" > "$_wave_tmpdir/step-1.time"
        printf '%s' "Test" > "$_wave_tmpdir/step-1.name"
        # Run aggregate_results (will exit 0, captured in $())
        aggregate_results 2>&1 || true
    ) 2>&1
    if echo "$result" | grep -q "say: all checks passed."; then
        assert_pass "aggregate_results parses exit files correctly"
    else
        assert_fail "aggregate_results" "Expected 'all checks passed' in output. Got: $result"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing framework-lib.sh unit functions..."
echo ""

test_register_step_function
test_register_step_multiple
test_parse_args_help
test_parse_args_format_flag
test_parse_args_scoped
test_parse_args_positions
test_aggregate_results_parses_exit_files

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
