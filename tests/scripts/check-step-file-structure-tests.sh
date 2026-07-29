#!/usr/bin/env bash
# Verify every step file exists for both platforms and meets structural requirements.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# ---- Verify POSIX check step files ----
test_posix_check_step_files_exist() {
    local missing=0
    for n in $(seq -w 1 20); do
        if [ ! -f "$REPO_ROOT/src/scripts/checks/check-steps/$n"*.sh ]; then
            assert_fail "POSIX check step $n" "Missing step file for number $n"
            ((missing++))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All 20 POSIX check step files exist"
    fi
}

test_posix_check_step_has_register_step() {
    local missing=0
    for f in "$REPO_ROOT/src/scripts/checks/check-steps/"*.sh; do
        if [ -f "$f" ]; then
            if ! grep -q 'register_step [0-9]' "$f"; then
                assert_fail "$(basename "$f")" "Missing register_step call"
                ((missing++))
            fi
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All POSIX check step files have register_step"
    fi
}

test_posix_check_step_no_overrides() {
    local violations=0
    for f in "$REPO_ROOT/src/scripts/checks/check-steps/"*.sh; do
        if [ -f "$f" ]; then
            if grep -q 'say\|error\|warn' "$f"; then
                # Allowed: step functions use say/error/warn.
                :
            fi
            # Verify no _step_prefix usage
            if grep -q '_step_prefix' "$f"; then
                assert_fail "$(basename "$f")" "Contains deprecated _step_prefix"
                ((violations++))
            fi
        fi
    done
    if [ "$violations" -eq 0 ]; then
        assert_pass "No step files reference deprecated _step_prefix"
    fi
}

test_posix_check_step_sequential_numbers() {
    local numbers
    numbers=$(for f in "$REPO_ROOT/src/scripts/checks/check-steps/"*.sh; do
        grep -oh 'register_step [0-9]*' "$f" | cut -d' ' -f2
    done | sort -n)
    local expected
    expected=$(seq 1 20)
    if [ "$numbers" = "$expected" ]; then
        assert_pass "POSIX check step numbers are sequential 1-20"
    else
        assert_fail "POSIX check step numbers" "Expected 1-20 sequential, got: $numbers"
    fi
}

# ---- Verify POSIX test step files ----
test_posix_test_step_files_exist() {
    local missing=0
    for n in $(seq 1 4); do
        if [ ! -f "$REPO_ROOT/src/scripts/tests/test-steps/0$n"*.sh ]; then
            assert_fail "POSIX test step $n" "Missing step file for number $n"
            ((missing++))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All 4 POSIX test step files exist"
    fi
}

test_posix_test_step_has_register_step() {
    local missing=0
    for f in "$REPO_ROOT/src/scripts/tests/test-steps/"*.sh; do
        if [ -f "$f" ]; then
            if ! grep -q 'register_step [0-9]' "$f"; then
                assert_fail "$(basename "$f")" "Missing register_step call"
                ((missing++))
            fi
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All POSIX test step files have register_step"
    fi
}

# ---- Verify Windows step files exist ----
test_windows_check_step_files_exist() {
    local missing=0
    for n in $(seq -w 1 20); do
        if [ ! -f "$REPO_ROOT/src/scripts/checks/check-steps/$n"*.ps1 ]; then
            assert_fail "Windows check step $n" "Missing step file for number $n"
            ((missing++))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All 20 Windows check step files exist"
    fi
}

test_windows_test_step_files_exist() {
    local missing=0
    for n in $(seq 1 4); do
        if [ ! -f "$REPO_ROOT/src/scripts/tests/test-steps/0$n"*.ps1 ]; then
            assert_fail "Windows test step $n" "Missing step file for number $n"
            ((missing++))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All 4 Windows test step files exist"
    fi
}

# ---- Verify ordering loaders ----
test_ordering_loaders_exist() {
    local missing=0
    for f in check-steps.sh check-steps.ps1; do
        if [ ! -f "$REPO_ROOT/src/scripts/checks/$f" ]; then
            assert_fail "Loader $f" "Missing"
            ((missing++))
        fi
    done
    for f in test-steps.sh test-steps.ps1; do
        if [ ! -f "$REPO_ROOT/src/scripts/tests/$f" ]; then
            assert_fail "Loader $f" "Missing"
            ((missing++))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_pass "All 4 ordering loaders exist"
    fi
}

# ---- Run tests ----
echo ""
echo "Testing check/test step file structure..."
echo ""

test_posix_check_step_files_exist
test_posix_check_step_has_register_step
test_posix_check_step_no_overrides
test_posix_check_step_sequential_numbers
test_posix_test_step_files_exist
test_posix_test_step_has_register_step
test_windows_check_step_files_exist
test_windows_test_step_files_exist
test_ordering_loaders_exist

echo ""
echo "--- Results: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
