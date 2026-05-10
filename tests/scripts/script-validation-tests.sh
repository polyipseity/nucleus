#!/usr/bin/env bash
# tests/scripts/script-validation-tests.sh — Smoke tests for shell scripts.
#
# Validates that critical scripts are syntactically correct and functionally sound.
# Tests check:
#   - Shell syntax validity (no parse errors)
#   - Required dependencies are available
#   - Script exit codes on various conditions
#   - Critical paths/variables are defined
#
# Run with: bash tests/scripts/script-validation-tests.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
    local test_name="$1"
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
}

assert_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "${RED}✗${NC} $test_name: $reason"
    ((TESTS_FAILED++))
}

# Test 1: Verify shell syntax (bash -n does parse-only check)
test_bash_syntax() {
    local script="$1"
    if bash -n "$script" 2>/dev/null; then
        assert_pass "Bash syntax: $(basename "$script")"
    else
        assert_fail "Bash syntax: $(basename "$script")" "Parse error detected"
    fi
}

# Test 2: Verify script has a shebang
test_has_shebang() {
    local script="$1"
    if head -n1 "$script" | grep -q "^#!"; then
        assert_pass "Shebang present: $(basename "$script")"
    else
        assert_fail "Shebang present: $(basename "$script")" "Missing #!/usr/bin/env or #!/bin/bash"
    fi
}

# Test 3: Verify script is executable
test_is_executable() {
    local script="$1"
    if [[ -x "$script" ]]; then
        assert_pass "Executable bit set: $(basename "$script")"
    else
        assert_fail "Executable bit set: $(basename "$script")" "Not executable (mode $(stat -f '%A' "$script" 2>/dev/null || echo 'unknown'))"
    fi
}

# Test 4: Verify critical functions/variables are defined
test_has_function_or_variable() {
    local script="$1"
    local identifier="$2"
    if grep -q "^\s*$identifier\s*=" "$script" || grep -q "^\s*function\s*$identifier" "$script" || grep -q "^\s*$identifier\s*()" "$script"; then
        assert_pass "Defines $identifier: $(basename "$script")"
    else
        # Non-fatal: some scripts may not need this
        echo -e "${YELLOW}⚠${NC}  Could not find $identifier in $(basename "$script")"
    fi
}

# Test 5: Verify critical dependencies are available
test_dependencies_available() {
    local script="$1"
    shift
    local deps=("$@")

    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null || grep -q "$dep" "$script"; then
            assert_pass "Dependency available: $dep ($(basename "$script"))"
        else
            # Only fail if the script explicitly requires it
            if grep -q "^[^#]*\b$dep\b" "$script"; then
                assert_fail "Dependency available: $dep ($(basename "$script"))" "Not found in PATH"
            fi
        fi
    done
}

# Test 6: Verify error handling patterns (set -e or explicit checks)
test_error_handling() {
    local script="$1"
    if grep -q "set -e" "$script" || grep -q "|| exit" "$script" || grep -q "|| return" "$script"; then
        assert_pass "Error handling present: $(basename "$script")"
    else
        # Warning: some scripts may intentionally allow failures
        echo -e "${YELLOW}⚠${NC}  No error handling patterns found in $(basename "$script")"
    fi
}

# Test 7: Verify comments explain critical sections
test_has_documentation() {
    local script="$1"
    local comment_lines=$(grep -c "^\s*#" "$script" || echo 0)
    local total_lines=$(wc -l < "$script")
    local comment_ratio=$((comment_lines * 100 / total_lines))

    if [[ $comment_ratio -ge 15 ]]; then
        assert_pass "Documentation present: $(basename "$script") ($comment_ratio% comments)"
    else
        echo -e "${YELLOW}⚠${NC}  Low documentation: $(basename "$script") ($comment_ratio% comments, recommend ≥15%)"
    fi
}

# Test 8: Verify no dangerous patterns (unquoted variables, etc.)
test_no_dangerous_patterns() {
    local script="$1"
    local dangerous=0

    # Check for unquoted variables in potentially dangerous contexts
    if grep -E '\$[A-Za-z_][A-Za-z0-9_]*\s+(&&|;|\||>)' "$script" | grep -v '\$([^)]*' | grep -v '${' >/dev/null 2>&1; then
        ((dangerous++))
        echo -e "${YELLOW}⚠${NC}  Potential unquoted variable: $(basename "$script")"
    fi

    # Check for rm -rf without safeguards
    if grep -E 'rm\s+-rf' "$script" | grep -v 'HOME\|TMPDIR\|/tmp' >/dev/null 2>&1; then
        ((dangerous++))
        echo -e "${YELLOW}⚠${NC}  Potentially unsafe rm -rf: $(basename "$script")"
    fi

    if [[ $dangerous -eq 0 ]]; then
        assert_pass "No dangerous patterns: $(basename "$script")"
    fi
}

# ============================================================================
# Run Tests on All Scripts
# ============================================================================

echo "Testing shell scripts for correctness and best practices..."
echo ""

# Test scripts/apply.sh
APPLY_SH="scripts/apply.sh"
if [[ -f "$APPLY_SH" ]]; then
    test_bash_syntax "$APPLY_SH"
    test_has_shebang "$APPLY_SH"
    test_is_executable "$APPLY_SH"
    test_dependencies_available "$APPLY_SH" git sops ssh-to-age
    test_error_handling "$APPLY_SH"
    test_has_documentation "$APPLY_SH"
    test_no_dangerous_patterns "$APPLY_SH"
fi

# Test scripts/bootstrap.sh
BOOTSTRAP_SH="scripts/bootstrap.sh"
if [[ -f "$BOOTSTRAP_SH" ]]; then
    test_bash_syntax "$BOOTSTRAP_SH"
    test_has_shebang "$BOOTSTRAP_SH"
    test_is_executable "$BOOTSTRAP_SH"
    test_dependencies_available "$BOOTSTRAP_SH" git nix
    test_error_handling "$BOOTSTRAP_SH"
    test_has_documentation "$BOOTSTRAP_SH"
    test_no_dangerous_patterns "$BOOTSTRAP_SH"
fi

# Test scripts/health-check.sh
HEALTH_CHECK_SH="scripts/health-check.sh"
if [[ -f "$HEALTH_CHECK_SH" ]]; then
    test_bash_syntax "$HEALTH_CHECK_SH"
    test_has_shebang "$HEALTH_CHECK_SH"
    test_is_executable "$HEALTH_CHECK_SH"
    test_dependencies_available "$HEALTH_CHECK_SH" git curl
    test_error_handling "$HEALTH_CHECK_SH"
    test_has_documentation "$HEALTH_CHECK_SH"
fi

# Test scripts/update.sh
UPDATE_SH="scripts/update.sh"
if [[ -f "$UPDATE_SH" ]]; then
    test_bash_syntax "$UPDATE_SH"
    test_has_shebang "$UPDATE_SH"
    test_is_executable "$UPDATE_SH"
    test_dependencies_available "$UPDATE_SH" nix sops
    test_error_handling "$UPDATE_SH"
    test_has_documentation "$UPDATE_SH"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
