#!/usr/bin/env bash
# Functional regression test for step 17 (suppression audit).
# Verifies the grep pipeline correctly distinguishes documented from undocumented
# suppressions. Runs in <1s with no external dependencies beyond POSIX tools.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# Replicates the core grep pipeline from step 17:
#   grep -Hn -E "shellcheck disable=|check-suppress:" "$file" # suppression_doc: test file documents the pipeline
#     | grep -v -E "reason:|suppression_doc:"
#     | sed "s/^/undoc_supp:/"
# Returns non-empty string when undocumented suppressions are found.
_run_s17_pipeline() {
    local file="$1"
    # shellcheck disable=SC2016 # reason: literal pattern for grep
    local _s17_grep_pattern="shellcheck disable=|check-suppress:" # suppression_doc: test pipeline variable
    grep -Hn -E "$_s17_grep_pattern" "$file" \
        | grep -v -E "reason:|suppression_doc:" \
        | sed "s/^/undoc_supp:/" 2>/dev/null || true
}

test_undocumented_shellcheck_suppression_fails() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\n# shellcheck disable=SC2086\n' > "$tmpfile" # suppression_doc: test data with suppression
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -n "$result" ]; then
        assert_pass "undocumented shellcheck suppression detected"
    else
        assert_fail "undocumented shellcheck suppression" "not detected"
    fi
    rm -f "$tmpfile"
}

test_documented_shellcheck_suppression_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\n# shellcheck disable=SC2086 # reason: intentional word splitting\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "documented shellcheck suppression (reason:) passes"
    else
        assert_fail "documented shellcheck suppression" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_undocumented_check_suppress_fails() {
    local tmpfile
    tmpfile=$(mktemp)
    printf 'some code\n# check-suppress:some-rule\n' > "$tmpfile" # suppression_doc: test data with suppression
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -n "$result" ]; then
        assert_pass "undocumented check-suppress detected"
    else
        assert_fail "undocumented check-suppress" "not detected"
    fi
    rm -f "$tmpfile"
}

test_documented_check_suppress_suppression_doc_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    printf 'some code\n# check-suppress:some-rule suppression_doc: intentional\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "documented check-suppress (suppression_doc:) passes"
    else
        assert_fail "documented check-suppress" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_documented_check_suppress_reason_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    printf 'some code\n# check-suppress:some-rule reason: intentional\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "documented check-suppress (reason:) passes"
    else
        assert_fail "documented check-suppress" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_self_referencing_grep_pattern_with_reason_not_flagged() {
    local tmpfile
    tmpfile=$(mktemp)
    # Simulates the self-referencing grep pattern variable with reason comment
    printf '_s17_grep_pattern="shellcheck disable=|check-suppress:"  # reason: self-reference\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "self-referencing grep pattern with reason not flagged"
    else
        assert_fail "self-referencing grep pattern" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_mixed_documented_and_undocumented_fails() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\n# shellcheck disable=SC2086 # reason: intentional\n# shellcheck disable=SC2154\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if echo "$result" | grep -q "SC2154"; then
        assert_pass "mixed documented/undocumented: undocumented SC2154 caught"
    else
        assert_fail "mixed documented/undocumented" "undocumented SC2154 not detected"
    fi
    rm -f "$tmpfile"
}

test_no_suppressions_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\necho "hello"\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipeline "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "file with no suppressions passes"
    else
        assert_fail "file with no suppressions" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

# ---- Run tests ----
echo ""
echo "Testing suppression audit (step 17) grep pipeline..."
echo ""

test_undocumented_shellcheck_suppression_fails
test_documented_shellcheck_suppression_passes
test_undocumented_check_suppress_fails
test_documented_check_suppress_suppression_doc_passes
test_documented_check_suppress_reason_passes
test_self_referencing_grep_pattern_with_reason_not_flagged
test_mixed_documented_and_undocumented_fails
test_no_suppressions_passes

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
