#!/usr/bin/env bash
# Validates that derive_repo_root and all nucleus scripts resolve the repository
# root independently of the current working directory.

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

# Determine the actual repo root by reading it from the script's own location.
# Use pwd -P to match derive_repo_root's symlink resolution.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# Test 1: derive_repo_root works from outside the repo when SCRIPT_DIR points inside it
test_derive_repo_root_from_outside_cwd() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="$REPO_ROOT/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/../src/scripts/lib.sh"
            derive_repo_root
        '
    ) || true
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/scripts"
    else
        assert_fail "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/scripts" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 2: derive_repo_root from src/scripts depth works from outside repo
test_derive_repo_root_from_src_scripts() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="$REPO_ROOT/src/scripts" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            . "$SCRIPT_DIR/lib.sh"
            derive_repo_root
        '
    ) || true
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/src/scripts"
    else
        assert_fail "derive_repo_root from /tmp with SCRIPT_DIR=$REPO_ROOT/src/scripts" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 3: NUCLEUS_REPO_ROOT env var takes priority over SCRIPT_DIR
test_env_var_priority() {
    local result
    result=$(
        cd /tmp
        SCRIPT_DIR="/nonexistent" \
        NUCLEUS_REPO_ROOT="$REPO_ROOT" \
        bash -euo pipefail -c '
            . "'"$REPO_ROOT"'/src/scripts/lib.sh"
            derive_repo_root
        ' 2>/dev/null
    ) || true
    if [ "$result" = "$REPO_ROOT" ]; then
        assert_pass "NUCLEUS_REPO_ROOT env var takes priority over invalid SCRIPT_DIR"
    else
        assert_fail "NUCLEUS_REPO_ROOT env var takes priority over invalid SCRIPT_DIR" "Expected '$REPO_ROOT', got '$result'"
    fi
}

# Test 4: derive_repo_root fails with clear error when nothing resolves
test_derive_repo_root_fails_cleanly() {
    local derr_output
    derr_output=$(
        SCRIPT_DIR="/tmp" \
        NUCLEUS_REPO_ROOT="" \
        bash -euo pipefail -c '
            cd /tmp
            . "'"$REPO_ROOT"'/src/scripts/lib.sh"
            derive_repo_root
        ' 2>&1
    ) || true
    if echo "$derr_output" | grep -q "cannot determine nucleus repository root"; then
        assert_pass "derive_repo_root fails with clear error when SCRIPT_DIR=/tmp"
    else
        assert_fail "derive_repo_root fails with clear error when SCRIPT_DIR=/tmp" "Output: '$derr_output'"
    fi
}

# Test 5: Scripts with --help work from outside repo
test_script_help_from_outside() {
    for script in \
        "$REPO_ROOT/scripts/gc.sh" \
        "$REPO_ROOT/scripts/logs.sh" \
        "$REPO_ROOT/scripts/health-check.sh" \
        "$REPO_ROOT/scripts/test.sh" \
        "$REPO_ROOT/scripts/svc.sh" \
        "$REPO_ROOT/scripts/vm-setup.sh" \
        "$REPO_ROOT/scripts/update.sh" \
        "$REPO_ROOT/scripts/ai-sync.sh" \
        "$REPO_ROOT/scripts/bootstrap.sh"; do
        local name
        name=$(basename "$script")
        # Run from /tmp with SCRIPT_DIR set so derive_repo_root can find the repo
        local result
        result=$(
            cd /tmp
            bash "$script" --help 2>/dev/null
        ) || true
        if [ -n "$result" ]; then
            assert_pass "$name --help from /tmp"
        else
            assert_fail "$name --help from /tmp" "No output or non-zero exit"
        fi
    done
}

# Run all tests
test_derive_repo_root_from_outside_cwd
test_derive_repo_root_from_src_scripts
test_env_var_priority
test_derive_repo_root_fails_cleanly
test_script_help_from_outside

# Summary
echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All $TESTS_PASSED cwd-independence tests passed.${NC}"
else
    echo -e "${RED}$TESTS_FAILED/$((TESTS_FAILED + TESTS_PASSED)) cwd-independence tests FAILED.${NC}" >&2
    exit 1
fi
