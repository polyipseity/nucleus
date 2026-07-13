#!/usr/bin/env bash
# Tests the rotate_log_file and rotate_logs_in_directory functions from lib.sh.
#
# Run with: bash tests/scripts/lib-log-rotation-tests.sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../src/scripts/lib.sh"

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

# Create a scratch directory for all test artifacts.
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# ---------------------------------------------------------------------------
# Test 1: rotate_log_file — no-op when file is below maxSize
# ---------------------------------------------------------------------------
test_below_maxsize_noop() {
    local logfile="$TEST_DIR/below.log"
    echo "small log content" > "$logfile"
    local before_size
    before_size=$(wc -c < "$logfile")
    rotate_log_file "$logfile" 10000000 4 false
    local after_size
    after_size=$(wc -c < "$logfile")
    if [ "$before_size" -eq "$after_size" ] && [ -f "$logfile" ]; then
        assert_pass "rotate_log_file: no-op when below maxSize"
    else
        assert_fail "rotate_log_file: no-op when below maxSize" "File was modified or removed"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: rotate_log_file — truncates when file exceeds maxSize, keeps archive
# ---------------------------------------------------------------------------
test_truncate_creates_archive() {
    local logfile="$TEST_DIR/rotate.log"
    # Write content larger than 10 bytes
    for _ in 1 2 3; do printf 'abcdefghij'; done > "$logfile"
    local before_size
    before_size=$(wc -c < "$logfile")
    rotate_log_file "$logfile" 10 2 false
    local after_size
    after_size=$(wc -c < "$logfile")
    if [ "$after_size" -eq 0 ] && [ -f "$logfile.1" ]; then
        assert_pass "rotate_log_file: truncates and creates .1 archive"
    else
        assert_fail "rotate_log_file: truncates and creates .1 archive" \
            "Truncated size=$after_size (expected 0), .1 exists=$([ -f "$logfile.1" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: rotate_log_file — shifts existing archives
# ---------------------------------------------------------------------------
test_archive_shifting() {
    local logfile="$TEST_DIR/shift.log"
    echo "content" > "$logfile"
    # Pre-populate .1 and .2
    echo "old archive 1" > "$logfile.1"
    echo "old archive 2" > "$logfile.2"
    rotate_log_file "$logfile" 1 3 false
    if [ -f "$logfile.1" ] && [ -f "$logfile.2" ] && [ -f "$logfile.3" ]; then
        assert_pass "rotate_log_file: shifts existing archives (.2→.3, .1→.2)"
    else
        assert_fail "rotate_log_file: shifts existing archives" \
            ".1 exists=$([ -f "$logfile.1" ] && echo yes || echo no) .2=$([ -f "$logfile.2" ] && echo yes || echo no) .3=$([ -f "$logfile.3" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: rotate_log_file — removes oldest archive when at maxFiles
# ---------------------------------------------------------------------------
test_oldest_archive_removed() {
    local logfile="$TEST_DIR/oldest.log"
    echo "content" > "$logfile"
    # Pre-populate all slots (.1, .2, .3)
    echo "archive 1" > "$logfile.1"
    echo "archive 2" > "$logfile.2"
    echo "archive 3" > "$logfile.3"
    rotate_log_file "$logfile" 1 3 false
    if [ -f "$logfile.1" ] && [ -f "$logfile.2" ] && [ -f "$logfile.3" ] && [ ! -f "$logfile.4" ]; then
        assert_pass "rotate_log_file: oldest archive removed when at maxFiles"
    else
        assert_fail "rotate_log_file: oldest archive removed" \
            ".1 exists=$([ -f "$logfile.1" ] && echo yes || echo no) .3=$([ -f "$logfile.3" ] && echo yes || echo no) .4 exists=$([ -f "$logfile.4" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: rotate_log_file — compresses archive when compress=true
# ---------------------------------------------------------------------------
test_compress_archive() {
    local logfile="$TEST_DIR/compress.log"
    # Write content larger than 10 bytes so rotation triggers
    for _ in 1 2 3 4 5; do printf 'abcdefghij'; done > "$logfile"
    rotate_log_file "$logfile" 10 2 true
    if [ -f "$logfile.1.gz" ]; then
        assert_pass "rotate_log_file: compresses archive when compress=true"
    else
        assert_fail "rotate_log_file: compresses archive when compress=true" ".1.gz not found"
    fi
}

# ---------------------------------------------------------------------------
# Test 6: rotate_log_file — maxfiles=0 truncates without archive
# ---------------------------------------------------------------------------
test_maxfiles_zero_truncates() {
    local logfile="$TEST_DIR/noarchive.log"
    for _ in 1 2 3 4 5; do printf 'abcdefghij'; done > "$logfile"
    rotate_log_file "$logfile" 10 0 false
    local after_size
    after_size=$(wc -c < "$logfile")
    if [ "$after_size" -eq 0 ] && [ ! -f "$logfile.1" ]; then
        assert_pass "rotate_log_file: maxfiles=0 truncates without archive"
    else
        assert_fail "rotate_log_file: maxfiles=0 truncates without archive" \
            "size=$after_size (expected 0), .1 exists=$([ -f "$logfile.1" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# Test 7: rotate_logs_in_directory — finds and rotates *.log files
# ---------------------------------------------------------------------------
test_rotate_directory() {
    local dir="$TEST_DIR/rotatedir"
    mkdir -p "$dir"
    # Create a small log file (should NOT be rotated) and a large one (should)
    echo "small" > "$dir/small.log"
    for _ in 1 2 3 4 5 6 7 8 9 10; do printf 'abcdefghij'; done > "$dir/large.log"
    rotate_logs_in_directory "$dir" 50 2 false
    if [ -f "$dir/small.log" ] && [ -f "$dir/large.log.1" ] && [ "$(wc -c < "$dir/large.log")" -eq 0 ]; then
        assert_pass "rotate_logs_in_directory: finds and rotates *.log files"
    else
        assert_fail "rotate_logs_in_directory: finds and rotates *.log files" \
            "small exists=$([ -f "$dir/small.log" ] && echo yes || echo no), large.1 exists=$([ -f "$dir/large.log.1" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# Test 8: rotate_logs_in_directory — no-op on missing directory
# ---------------------------------------------------------------------------
test_rotate_missing_dir() {
    local result
    result=$(rotate_logs_in_directory "$TEST_DIR/nonexistent" 10 2 false 2>&1) || true  # undoc-supp: expected failure — testing error handling for nonexistent path
    if [ -z "$result" ]; then
        assert_pass "rotate_logs_in_directory: no-op on missing directory"
    else
        assert_fail "rotate_logs_in_directory: no-op on missing directory" "Produced output: $result"
    fi
}

# ---------------------------------------------------------------------------
# Test 9: rotate_log_file — no-op on missing file
# ---------------------------------------------------------------------------
test_missing_file_noop() {
    local result
    result=$(rotate_log_file "$TEST_DIR/nonexistent.log" 10 2 false 2>&1) || true  # undoc-supp: expected failure — testing error handling for nonexistent path
    if [ -z "$result" ] && [ ! -f "$TEST_DIR/nonexistent.log.1" ]; then
        assert_pass "rotate_log_file: no-op on missing file"
    else
        assert_fail "rotate_log_file: no-op on missing file" "Produced output or created archive"
    fi
}

# ---- run all tests ----
echo "Testing lib.sh log rotation functions"
echo ""

test_below_maxsize_noop
test_truncate_creates_archive
test_archive_shifting
test_oldest_archive_removed
test_compress_archive
test_maxfiles_zero_truncates
test_rotate_directory
test_rotate_missing_dir
test_missing_file_noop

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [ "$TESTS_FAILED" -eq 0 ]; then
    exit 0
else
    exit 1
fi
