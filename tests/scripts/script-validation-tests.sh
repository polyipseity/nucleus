#!/usr/bin/env bash
# script-validation-tests.sh — Smoke tests for shell scripts in the nucleus repository.
#
# Validates that critical shell scripts in scripts/ and src/scripts/ are
# syntactically correct, follow best practices (shebang, executable bit, strict
# mode, error handling, documentation), and have required dependencies available.
# Runs a suite of test functions (test_bash_syntax, test_has_shebang, etc.)
# against each discovered script and reports pass/fail counts.
#
# Arguments:
#   (none)        No arguments accepted.
#
# Environment variables:
#   (none)        No environment variables used.
#
# Exit conditions:
#   0 on success (all tests pass); non-zero if any test fails.

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
    ((++TESTS_PASSED))
}

assert_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "${RED}✗${NC} $test_name: $reason"
    ((++TESTS_FAILED))
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
# Reserved for future test expansion; currently not invoked.
# Uncomment when adding identifier checks to a specific test.
# test_has_function_or_variable() {
#     local script="$1"
#     local identifier="$2"
#     if grep -q "^\s*$identifier\s*=" "$script" || grep -q "^\s*function\s*$identifier" "$script" || grep -q "^\s*$identifier\s*()" "$script"; then
#         assert_pass "Defines $identifier: $(basename "$script")"
#     else
#         # Non-fatal: some scripts may not need this
#         echo -e "${YELLOW}⚠${NC}  Could not find $identifier in $(basename "$script")"
#     fi
# }

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
    local comment_lines
    comment_lines=$(grep -c "^\s*#" "$script" || echo 0)
    local total_lines
    total_lines=$(wc -l < "$script")
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
    # shellcheck disable=SC2016  # $ chars are literal regex metacharacters, not shell expansions.
    if grep -E '\$[A-Za-z_][A-Za-z0-9_]*\s+(&&|;|\||>)' "$script" | grep -v '\$([^)]*' | grep -v '${' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        echo -e "${YELLOW}⚠${NC}  Potential unquoted variable: $(basename "$script")"
    fi

    # Check for rm -rf without safeguards
    if grep -E 'rm\s+-rf' "$script" | grep -v 'HOME\|TMPDIR\|/tmp' >/dev/null 2>&1; then
        dangerous=$((dangerous + 1))
        echo -e "${YELLOW}⚠${NC}  Potentially unsafe rm -rf: $(basename "$script")"
    fi

    if [[ $dangerous -eq 0 ]]; then
        assert_pass "No dangerous patterns: $(basename "$script")"
    fi
}

# Test 9: Verify bootstrap direnv auto-allow is strictly repo-scoped
test_bootstrap_direnv_scope() {
    local script="$1"

    # shellcheck disable=SC2016  # Match literal "$REPO_ROOT" text in script source.
    if ! grep -Fq 'direnv allow "$REPO_ROOT"' "$script"; then
        assert_fail "Bootstrap direnv scope: $(basename "$script")" "Missing repo-root direnv allow invocation"
        return
    fi

    # shellcheck disable=SC2016  # Match literal "$REPO_ROOT" text in script source.
    if ! grep -Fq 'basename -- "$REPO_ROOT"' "$script" || ! grep -Fq '"nucleus"' "$script"; then
        assert_fail "Bootstrap direnv scope: $(basename "$script")" "Missing nucleus-only scope guard"
        return
    fi

    assert_pass "Bootstrap direnv scope: $(basename "$script")"
}

# Test 10: Verify strict shell mode (set -euo pipefail)
# Ensures scripts fail fast on undefined variables and pipe errors.
test_strict_shell_mode() {
    local script="$1"
    if grep -q 'set -euo pipefail' "$script"; then
        assert_pass "Strict shell mode: $(basename "$script")"
    else
        assert_fail "Strict shell mode: $(basename "$script")" "Missing set -euo pipefail"
    fi
}

# Test 11: Verify usage_std function is defined (either local or via lib.sh)
test_usage_std_present() {
    local script="$1"
    if grep -Eq '^\s*usage_std\(\)' "$script" || grep -Eq '^\s*\.\s+.*lib\.sh' "$script"; then
        assert_pass "usage_std present: $(basename "$script")"
    else
        echo -e "${YELLOW}⚠${NC}  No usage_std found in $(basename "$script")"
    fi
}

# Test 12: Verify -h|--help handler is present
test_help_handler() {
    local script="$1"
    if grep -Eq '\s+-h\||--help\)' "$script"; then
        assert_pass "Help handler present: $(basename "$script")"
    else
        assert_fail "Help handler present: $(basename "$script")" "Missing -h|--help case"
    fi
}

# ============================================================================
# Run Tests on All Scripts
# ============================================================================

echo "Testing shell scripts for correctness and best practices..."
echo ""

# Test scripts/vm-setup.sh
VM_SETUP_SH="scripts/vm-setup.sh"
if [[ -f "$VM_SETUP_SH" ]]; then
    test_bash_syntax "$VM_SETUP_SH"
    test_has_shebang "$VM_SETUP_SH"
    test_is_executable "$VM_SETUP_SH"
    test_dependencies_available "$VM_SETUP_SH" qemu-system-aarch64 qemu-system-x86_64 rsync
    test_error_handling "$VM_SETUP_SH"
    test_has_documentation "$VM_SETUP_SH"
    test_no_dangerous_patterns "$VM_SETUP_SH"
    test_strict_shell_mode "$VM_SETUP_SH"
    test_usage_std_present "$VM_SETUP_SH"
    test_help_handler "$VM_SETUP_SH"

    # Verify Apple Silicon arm64 tcg fallback: HVF on arm64 macOS only
    # accelerates AArch64 guests; x86_64 Windows QEMU builds must use tcg.
    # Without this fix, qemu-system-x86_64 -accel hvf fails with
    # "invalid accelerator hvf" on Apple Silicon.
    if grep -q 'arm64' "$VM_SETUP_SH" && grep -q "accelerator='tcg'" "$VM_SETUP_SH"; then
        assert_pass "arm64 tcg fallback present: $(basename "$VM_SETUP_SH")"
    else
        assert_fail "arm64 tcg fallback present: $(basename "$VM_SETUP_SH")" \
            "Missing Apple Silicon tcg fallback for x86_64 QEMU builds"
    fi
fi

# Test scripts/apply.sh → src/scripts/apply.sh
APPLY_SH="src/scripts/apply.sh"
if [[ -f "$APPLY_SH" ]]; then
    test_bash_syntax "$APPLY_SH"
    test_has_shebang "$APPLY_SH"
    test_is_executable "$APPLY_SH"
    test_dependencies_available "$APPLY_SH" git sops ssh-to-age
    test_error_handling "$APPLY_SH"
    test_has_documentation "$APPLY_SH"
    test_no_dangerous_patterns "$APPLY_SH"
    test_strict_shell_mode "$APPLY_SH"
    test_usage_std_present "$APPLY_SH"
    test_help_handler "$APPLY_SH"
fi

# Test scripts/bootstrap.sh
BOOTSTRAP_SH="scripts/bootstrap.sh"
if [[ -f "$BOOTSTRAP_SH" ]]; then
    test_bash_syntax "$BOOTSTRAP_SH"
    test_has_shebang "$BOOTSTRAP_SH"
    test_is_executable "$BOOTSTRAP_SH"
    test_dependencies_available "$BOOTSTRAP_SH" git nix
    test_error_handling "$BOOTSTRAP_SH"
    test_bootstrap_direnv_scope "$BOOTSTRAP_SH"
    test_has_documentation "$BOOTSTRAP_SH"
    test_no_dangerous_patterns "$BOOTSTRAP_SH"
    test_strict_shell_mode "$BOOTSTRAP_SH"
    test_usage_std_present "$BOOTSTRAP_SH"
    test_help_handler "$BOOTSTRAP_SH"
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
    test_strict_shell_mode "$HEALTH_CHECK_SH"
    test_usage_std_present "$HEALTH_CHECK_SH"
    test_help_handler "$HEALTH_CHECK_SH"
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
    test_strict_shell_mode "$UPDATE_SH"
    test_usage_std_present "$UPDATE_SH"
    test_help_handler "$UPDATE_SH"
fi

# Test scripts/ai-sync.sh
AI_SYNC_SH="scripts/ai-sync.sh"
if [[ -f "$AI_SYNC_SH" ]]; then
    test_bash_syntax "$AI_SYNC_SH"
    test_has_shebang "$AI_SYNC_SH"
    test_is_executable "$AI_SYNC_SH"
    test_error_handling "$AI_SYNC_SH"
    test_has_documentation "$AI_SYNC_SH"
    test_no_dangerous_patterns "$AI_SYNC_SH"
    test_strict_shell_mode "$AI_SYNC_SH"
    test_usage_std_present "$AI_SYNC_SH"
    test_help_handler "$AI_SYNC_SH"
fi

# Test scripts/cloud-setup.sh
CLOUD_SETUP_SH="scripts/cloud-setup.sh"
if [[ -f "$CLOUD_SETUP_SH" ]]; then
    test_bash_syntax "$CLOUD_SETUP_SH"
    test_has_shebang "$CLOUD_SETUP_SH"
    test_is_executable "$CLOUD_SETUP_SH"
    test_dependencies_available "$CLOUD_SETUP_SH" git rsync
    test_error_handling "$CLOUD_SETUP_SH"
    test_has_documentation "$CLOUD_SETUP_SH"
    test_no_dangerous_patterns "$CLOUD_SETUP_SH"
    test_strict_shell_mode "$CLOUD_SETUP_SH"
    test_usage_std_present "$CLOUD_SETUP_SH"
    test_help_handler "$CLOUD_SETUP_SH"
fi

# Test scripts/gc.sh
GC_SH="scripts/gc.sh"
if [[ -f "$GC_SH" ]]; then
    test_bash_syntax "$GC_SH"
    test_has_shebang "$GC_SH"
    test_is_executable "$GC_SH"
    test_dependencies_available "$GC_SH" git nix
    test_error_handling "$GC_SH"
    test_has_documentation "$GC_SH"
    test_no_dangerous_patterns "$GC_SH"
    test_strict_shell_mode "$GC_SH"
    test_usage_std_present "$GC_SH"
    test_help_handler "$GC_SH"
fi

# Test scripts/replica-reset.sh
REPLICA_RESET_SH="scripts/replica-reset.sh"
if [[ -f "$REPLICA_RESET_SH" ]]; then
    test_bash_syntax "$REPLICA_RESET_SH"
    test_has_shebang "$REPLICA_RESET_SH"
    test_is_executable "$REPLICA_RESET_SH"
    test_dependencies_available "$REPLICA_RESET_SH" git rsync
    test_error_handling "$REPLICA_RESET_SH"
    test_has_documentation "$REPLICA_RESET_SH"
    test_no_dangerous_patterns "$REPLICA_RESET_SH"
    test_strict_shell_mode "$REPLICA_RESET_SH"
    test_usage_std_present "$REPLICA_RESET_SH"
    test_help_handler "$REPLICA_RESET_SH"
fi

# Test scripts/replica-sync.sh
REPLICA_SYNC_SH="scripts/replica-sync.sh"
if [[ -f "$REPLICA_SYNC_SH" ]]; then
    test_bash_syntax "$REPLICA_SYNC_SH"
    test_has_shebang "$REPLICA_SYNC_SH"
    test_is_executable "$REPLICA_SYNC_SH"
    test_dependencies_available "$REPLICA_SYNC_SH" git rsync
    test_error_handling "$REPLICA_SYNC_SH"
    test_has_documentation "$REPLICA_SYNC_SH"
    test_no_dangerous_patterns "$REPLICA_SYNC_SH"
    test_strict_shell_mode "$REPLICA_SYNC_SH"
    test_usage_std_present "$REPLICA_SYNC_SH"
    test_help_handler "$REPLICA_SYNC_SH"
fi

# Test scripts/check-sh.sh
CHECK_SH_SH="scripts/check-sh.sh"
if [[ -f "$CHECK_SH_SH" ]]; then
    test_bash_syntax "$CHECK_SH_SH"
    test_has_shebang "$CHECK_SH_SH"
    test_is_executable "$CHECK_SH_SH"
    test_dependencies_available "$CHECK_SH_SH" shellcheck
    test_error_handling "$CHECK_SH_SH"
    test_has_documentation "$CHECK_SH_SH"
    test_no_dangerous_patterns "$CHECK_SH_SH"
    test_strict_shell_mode "$CHECK_SH_SH"
    test_usage_std_present "$CHECK_SH_SH"
    test_help_handler "$CHECK_SH_SH"
fi

# Test scripts/check.sh
CHECK_SH="scripts/check.sh"
if [[ -f "$CHECK_SH" ]]; then
    test_bash_syntax "$CHECK_SH"
    test_has_shebang "$CHECK_SH"
    test_is_executable "$CHECK_SH"
    test_dependencies_available "$CHECK_SH" shellcheck pwsh packer nix deadnix
    test_error_handling "$CHECK_SH"
    test_has_documentation "$CHECK_SH"
    test_no_dangerous_patterns "$CHECK_SH"
    test_strict_shell_mode "$CHECK_SH"
    test_usage_std_present "$CHECK_SH"
    test_help_handler "$CHECK_SH"
fi

# Test scripts/svc.sh (macOS-only: launchctl-based service management)
SVC_SH="scripts/svc.sh"
if [[ -f "$SVC_SH" ]]; then
    test_bash_syntax "$SVC_SH"
    test_has_shebang "$SVC_SH"
    test_is_executable "$SVC_SH"
    test_dependencies_available "$SVC_SH" jq
    test_error_handling "$SVC_SH"
    test_has_documentation "$SVC_SH"
    test_no_dangerous_patterns "$SVC_SH"
    test_strict_shell_mode "$SVC_SH"
    test_usage_std_present "$SVC_SH"
    test_help_handler "$SVC_SH"

    # Runtime sanity: svc list produces expected table headers
    SVC_LIST_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" "$SVC_SH" list 2>&1 || true)
    if echo "$SVC_LIST_OUTPUT" | grep -q "Service.*Status.*Running.*PID"; then
        assert_pass "svc list: table headers present"
    else
        assert_fail "svc list: table headers present" "Missing expected table header line"
    fi
    if echo "$SVC_LIST_OUTPUT" | grep -qE "Ollama|LiteLLM|Jellyfin"; then
        assert_pass "svc list: known services listed"
    else
        assert_fail "svc list: known services listed" "No expected service names found in output"
    fi
    if ! echo "$SVC_LIST_OUTPUT" | grep -q "unknown"; then
        assert_pass "svc list: no unknown services"
    else
        assert_fail "svc list: no unknown services" "Output contains 'unknown' (likely jq parse failure)"
    fi

    # Runtime sanity: svc list --json produces valid JSON
    SVC_JSON_OUTPUT=$(NUCLEUS_REPO_ROOT="$PWD" "$SVC_SH" list --json 2>&1 || true)
    if echo "$SVC_JSON_OUTPUT" | jq -e '.svc_version == "1"' >/dev/null 2>&1; then
        assert_pass "svc list --json: valid JSON with version"
    else
        assert_fail "svc list --json: valid JSON with version" "Output is not valid JSON or missing svc_version"
    fi
    if echo "$SVC_JSON_OUTPUT" | jq -e 'has("services")' >/dev/null 2>&1; then
        assert_pass "svc list --json: services key present"
    else
        assert_fail "svc list --json: services key present" "Missing services key in JSON output"
    fi
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
