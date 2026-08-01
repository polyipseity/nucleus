#!/usr/bin/env bash
# Functional regression test for step 17 (suppression audit).
# Verifies the grep pipeline and the bare '|| true' detection distinguish
# documented from undocumented suppressions. Runs in <1s with no external
# dependencies beyond POSIX tools.

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

# Replicates the bare '|| true' detection pass from step 17 (sh twin): flags a
# bare '|| true' unless documented by '# check-suppress:suppression_doc:' on the
# same or preceding line. Comment-only lines are skipped. The tests/ exemption is
# the caller's path guard, replicated by _s17_is_exempt.
_run_s17_pipe_true() {
    local file="$1"
    awk '
      /^[[:space:]]*#/ { prev = $0; next }
      /\|\| true/ {
        if ($0 !~ /check-suppress:suppression_doc:/ && prev !~ /# check-suppress:suppression_doc:/) {
          print FILENAME ":" FNR ":|| true: " $0
        }
      }
      { prev = $0 }
    ' "$file" | sed "s/^/undoc_supp:/" 2>/dev/null || true
}

# Replicates the sh twin's test-fixture exemption for || true detection.
_s17_is_exempt() {
    case "$1" in
        *"/tests/"* | "tests/"*) return 0 ;;
        *) return 1 ;;
    esac
}

test_undocumented_pipe_true_fails() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\necho hi || true\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipe_true "$tmpfile")
    if [ -n "$result" ]; then
        assert_pass "undocumented || true detected"
    else
        assert_fail "undocumented || true" "not detected"
    fi
    rm -f "$tmpfile"
}

test_documented_pipe_true_same_line_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\necho hi || true  # check-suppress:suppression_doc: intentional\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipe_true "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "|| true with same-line suppression_doc passes"
    else
        assert_fail "|| true with same-line suppression_doc" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_documented_pipe_true_previous_line_passes() {
    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2016 # reason: fixture content contains a literal $_f
    printf '#!/bin/bash\n# check-suppress:suppression_doc: intentional\ncat "$_f" 2>/dev/null || true\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipe_true "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "|| true with preceding-line suppression_doc passes"
    else
        assert_fail "|| true with preceding-line suppression_doc" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_pipe_true_in_comment_not_flagged() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '#!/bin/bash\n# Soft-fail (|| true) because the tool is flaky\n' > "$tmpfile"
    local result
    result=$(_run_s17_pipe_true "$tmpfile")
    if [ -z "$result" ]; then
        assert_pass "|| true inside a comment not flagged"
    else
        assert_fail "|| true inside a comment" "unexpectedly flagged: $result"
    fi
    rm -f "$tmpfile"
}

test_pipe_true_test_fixture_exempt() {
    local fixture sub
    fixture=$(mktemp -d)
    sub="$fixture/tests/x.sh"
    mkdir -p "$(dirname "$sub")"
    printf '#!/bin/bash\necho hi || true\n' > "$sub"
    if _s17_is_exempt "$sub"; then
        assert_pass "tests/ fixtures exempt from || true detection"
    else
        assert_fail "tests/ fixture exemption" "path not recognized as exempt"
    fi
    rm -rf "$fixture"
}

test_pipe_true_production_path_not_exempt() {
    if _s17_is_exempt "src/scripts/foo.sh"; then
        assert_fail "production path exemption" "src/scripts path wrongly exempt"
    else
        assert_pass "production paths scanned for || true"
    fi
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
test_undocumented_pipe_true_fails
test_documented_pipe_true_same_line_passes
test_documented_pipe_true_previous_line_passes
test_pipe_true_in_comment_not_flagged
test_pipe_true_test_fixture_exempt
test_pipe_true_production_path_not_exempt
test_mixed_documented_and_undocumented_fails
test_no_suppressions_passes

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
