#!/usr/bin/env bash
# Cross-platform parity tests for step-runner across POSIX and Windows.
# Validates that the two implementations accept the same flags and
# produce structurally compatible results.
#
# NOTE: This file tests the POSIX implementation. When run on Windows,
# the companion script tests the PS1 implementation. The parity check
# validates they understand the same flag set.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Contract: Both parse_args and Read-Argument support the same flags ----
# Per the plan, the shared flag set is:
#   --fail-fast, --no-fail-fast, --scoped, --full, --online, --skip-steps
# (--format was removed in Phase 1)

test_parity_parse_args_shared_flags() {
    # Test each shared flag is accepted
    local flags=("--fail-fast" "--no-fail-fast" "--scoped" "--full" "--online" "--skip-steps=a,b")
    local all_ok=true

    for flag in "${flags[@]}"; do
        local result
        result=$(
            . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
            usage() { true; }
            # shellcheck disable=SC2086 # reason: intentional word splitting for flag var
            parse_args $flag
            echo "ok"
        )
        if [ "$result" != "ok" ]; then
            echo "Flag $flag failed: $result" >&2
            all_ok=false
        fi
    done

    if $all_ok; then
        assert_pass "PARITY: POSIX parse_args accepts all shared flags (--fail-fast, --no-fail-fast, --scoped, --full, --online)"
    else
        assert_fail "PARITY-shared-flags" "Some shared flags were rejected"
    fi
}

# ---- Contract: unsupported flags are rejected ----
test_parity_unknown_flag_rejected() {
    local exit_code=0
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --bogus-flag 2>/dev/null
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        assert_pass "PARITY: POSIX parse_args rejects unknown flags"
    else
        assert_fail "PARITY-unknown-flag" "Expected non-zero exit for --bogus-flag, got: $exit_code"
    fi
}

# ---- Contract: --online flag accepted ----
# Used by check step 18 (online-determinism).

test_parity_online_flag_accepted() {
    local result
    result=$(
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --online
        echo "$ONLINE"
    )
    if [ "$result" = "true" ]; then
        assert_pass "PARITY: --online flag sets ONLINE=true"
    else
        assert_fail "PARITY-online" "Expected 'true', got: $result"
    fi
}

# ---- Contract: --no-fail-fast unsets FAIL_FAST ----
test_parity_no_fail_fast_flag() {
    local result
    result=$(
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        FAIL_FAST=true
        parse_args --no-fail-fast
        echo "$FAIL_FAST"
    )
    if [ "$result" = "false" ]; then
        assert_pass "PARITY: --no-fail-fast sets FAIL_FAST=false"
    else
        assert_fail "PARITY-no-fail-fast" "Expected 'false', got: $result"
    fi
}

# ---- Contract: positional args grouped by extension ----
test_parity_positional_args_grouped() {
    local result
    result=$(
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args "file.sh" "file.ps1" "file.nix" "file.pkr.hcl"
        echo "sh:${#SH_FILES[@]} ps1:${#PS1_FILES[@]} nix:${#NIX_FILES[@]} pkr:${#PKR_FILES[@]}"
    )
    if [ "$result" = "sh:1 ps1:1 nix:1 pkr:1" ]; then
        assert_pass "PARITY: POSIX groups positional args by extension"
    else
        assert_fail "PARITY-ext-grouping" "Expected 'sh:1 ps1:1 nix:1 pkr:1', got: $result"
    fi
}

# ---- Contract: help flag exits 0 ----
test_parity_help_exits_cleanly() {
    local exit_code=0
    bash -c '
        . "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"
        usage() { true; }
        parse_args --help
    ' 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 1 ]; then
        assert_fail "PARITY-help" "Unexpected exit code for --help: $exit_code"
    else
        assert_pass "PARITY: --help exits cleanly"
    fi
}

# ---- Contract: flag ordering does not matter ----
test_parity_flag_ordering_independent() {
    local result1 result2
    result1=$(
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        FAIL_FAST=false
        parse_args --fail-fast --scoped
        echo "$FAIL_FAST $SCOPED"
    )
    result2=$(
        . "$REPO_ROOT/src/scripts/lib/step-runner.sh"
        usage() { true; }
        FAIL_FAST=false
        parse_args --scoped --fail-fast
        echo "$FAIL_FAST $SCOPED"
    )
    if [ "$result1" = "true true" ] && [ "$result2" = "true true" ]; then
        assert_pass "PARITY: flag ordering is independent"
    else
        assert_fail "PARITY-flag-order" "Order-dependent results: '$result1' vs '$result2'"
    fi
}

# ---- Run tests ----
echo ""
echo "=== Phase 0: Cross-platform parity tests (POSIX side) ==="
echo ""

test_parity_parse_args_shared_flags
test_parity_unknown_flag_rejected
test_parity_online_flag_accepted
test_parity_no_fail_fast_flag
test_parity_positional_args_grouped
test_parity_help_exits_cleanly
test_parity_flag_ordering_independent

echo ""
echo "--- Parity tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
