#!/usr/bin/env bash
# Shared test library: counters, assertions, and color helpers.
# Source this after setting SCRIPT_DIR and/or REPO_ROOT.

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
