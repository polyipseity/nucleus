#!/usr/bin/env bash
# Tests for lib.sh output formatting helpers: say, error, warn, dry_run, nuc_done, section, _nuc_prefix.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
    local test_name="$1"
    echo -e "${GREEN}✓${NC} $test_name"
    ((++TESTS_PASSED))
}

assert_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "${RED}✗${NC} $test_name: $reason"
    ((++TESTS_FAILED))
}

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---------------------------------------------------------------------------
# Helper: run a code snippet inside a mock nucleus-* script and capture
# its output/exit code. Simulates a script named "nucleus-foo" so that
# _nuc_prefix derivation gives "foo".
# ---------------------------------------------------------------------------
mock_nucleus_script() {
    local code="$1"
    # Use a temp dir with a mock script name
    local tmpdir; tmpdir="$(mktemp -d)"
    # Symlink to a mock script to simulate nucleus-foo
    mkdir -p "$tmpdir/bin"
    cat > "$tmpdir/bin/nucleus-foo" <<'MOCKSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
MOCKSCRIPT
    # Append the lib.sh sourcing + test code
    echo ". '${REPO_ROOT}/src/scripts/lib.sh'" >> "$tmpdir/bin/nucleus-foo"
    echo "$code" >> "$tmpdir/bin/nucleus-foo"
    chmod +x "$tmpdir/bin/nucleus-foo"
    local result
    result=$("$tmpdir/bin/nucleus-foo" 2>/tmp/nucleus-test-stderr-$$; echo "EXIT:$?")
    local stdout; stdout="${result%EXIT:*}"
    local ecode; ecode="${result##*EXIT:}"
    local stderr; stderr="$(cat /tmp/nucleus-test-stderr-$$)"
    rm -rf "$tmpdir" "/tmp/nucleus-test-stderr-$$"
    printf '%s' "$stdout"
    printf '%s' "$stderr" >&2
    return "$ecode"
}

# ---------------------------------------------------------------------------
# Test: _nuc_prefix derivation
# ---------------------------------------------------------------------------
test_prefix_derivation() {
    local result
    # shellcheck disable=SC2016 # $_nuc_prefix is expanded inside mock_nucleus_script, not here
    result=$(mock_nucleus_script 'printf "%s" "$_nuc_prefix"' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo" ]; then
        assert_pass "_nuc_prefix derives 'foo' from 'nucleus-foo'"
    else
        assert_fail "_nuc_prefix derivation" "Expected 'foo', got '$result'"
    fi
}

# ---------------------------------------------------------------------------
# Test: say writes to stdout
# ---------------------------------------------------------------------------
test_say_stdout() {
    local result
    result=$(mock_nucleus_script 'say "hello world"' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo: hello world" ]; then
        assert_pass "say writes 'foo: hello world' to stdout"
    else
        assert_fail "say stdout format" "Expected 'foo: hello world', got '$result'"
    fi
}

test_say_multiple_args() {
    local result
    result=$(mock_nucleus_script 'say "hello" "world"' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo: hello world" ]; then
        assert_pass "say joins multiple arguments"
    else
        assert_fail "say multiple args" "Expected 'foo: hello world', got '$result'"
    fi
}

# ---------------------------------------------------------------------------
# Test: error writes to stderr and returns 1
# ---------------------------------------------------------------------------
test_error_stderr() {
    local stdout stderr ecode
    stdout=$(mock_nucleus_script 'error "something failed"' 2>/tmp/err.$$; echo "EXIT:$?")
    ecode="${stdout##*EXIT:}"
    stderr="$(cat /tmp/err.$$)"; rm -f /tmp/err.$$
    if [ "$stderr" = "foo: error: something failed" ] && [ "$ecode" = "1" ]; then
        assert_pass "error writes 'foo: error: ...' to stderr and returns 1"
    else
        assert_fail "error stderr/exit" "Expected stderr='foo: error: something failed' exit=1, got stderr='$stderr' exit=$ecode"
    fi
}

# ---------------------------------------------------------------------------
# Test: warn writes to stderr
# ---------------------------------------------------------------------------
test_warn_stderr() {
    local stdout stderr ecode
    stdout=$(mock_nucleus_script 'warn "beware"' 2>/tmp/err.$$; echo "EXIT:$?")
    ecode="${stdout##*EXIT:}"
    stderr="$(cat /tmp/err.$$)"; rm -f /tmp/err.$$
    if [ "$stderr" = "foo: warning: beware" ] && [ "$ecode" = "0" ]; then
        assert_pass "warn writes 'foo: warning: ...' to stderr and returns 0"
    else
        assert_fail "warn stderr/exit" "Expected stderr='foo: warning: beware' exit=0, got stderr='$stderr' exit=$ecode"
    fi
}

# ---------------------------------------------------------------------------
# Test: dry_run writes to stdout with [dry-run] prefix
# ---------------------------------------------------------------------------
test_dry_run_stdout() {
    local result
    result=$(mock_nucleus_script 'dry_run "would do x"' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo: [dry-run] would do x" ]; then
        assert_pass "dry_run writes 'foo: [dry-run] ...' to stdout"
    else
        assert_fail "dry_run format" "Expected 'foo: [dry-run] would do x', got '$result'"
    fi
}

# ---------------------------------------------------------------------------
# Test: nuc_done writes to stdout
# ---------------------------------------------------------------------------
test_nuc_done_stdout() {
    local result
    result=$(mock_nucleus_script 'nuc_done' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo: done" ]; then
        assert_pass "nuc_done writes 'foo: done' to stdout"
    else
        assert_fail "nuc_done format" "Expected 'foo: done', got '$result'"
    fi
}

# ---------------------------------------------------------------------------
# Test: section outputs header with step numbering
# ---------------------------------------------------------------------------
test_section_format() {
    local result
    result=$(mock_nucleus_script '
section 1 "first"
section 2 "second"
' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$result" | grep -q "=== \[1\] first ===" && echo "$result" | grep -q "=== \[2\] second ==="; then
        assert_pass "section outputs correct format with step numbers"
    else
        assert_fail "section format" "Expected '=== [1] first ===' and '=== [2] second ===', got '$result'"
    fi
}

test_section_newline_before() {
    local result
    result=$(mock_nucleus_script 'section 1 "test"' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if echo "$result" | grep -q "^$"; then
        assert_pass "section starts with a blank line"
    else
        assert_fail "section leading newline" "Expected blank line before section header"
    fi
}

# ---------------------------------------------------------------------------
# Test: helpers handle empty messages
# ---------------------------------------------------------------------------
test_say_empty() {
    local result
    result=$(mock_nucleus_script 'say ""' 2>/dev/null) || true  # undoc-supp: test probe — capturing output; exit code is discarded so set -e doesn't abort test
    if [ "$result" = "foo: " ]; then
        assert_pass "say handles empty message"
    else
        assert_fail "say empty" "Expected 'foo: ', got '$result'"
    fi
}

test_error_empty() {
    local stderr ecode
    stderr=$(mock_nucleus_script 'error ""' 2>/tmp/err.$$; echo "EXIT:$?")
    ecode="${stderr##*EXIT:}"
    local err; err="$(cat /tmp/err.$$)"; rm -f /tmp/err.$$
    if [ "$err" = "foo: error: " ] && [ "$ecode" = "1" ]; then
        assert_pass "error handles empty message"
    else
        assert_fail "error empty" "Expected stderr='foo: error: ' exit=1"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_prefix_derivation
test_say_stdout
test_say_multiple_args
test_error_stderr
test_warn_stderr
test_dry_run_stdout
test_nuc_done_stdout
test_section_format
test_section_newline_before
test_say_empty
test_error_empty

echo "---"
echo "lib.sh output-format tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
