#!/usr/bin/env bash
# Phase 4a: Step 01 FORMAT_NIX removal — structure tests.
# These verify that FORMAT_NIX, --format, and --fail-on-change are gone
# from the POSIX step 01 file.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
STEP01="$REPO_ROOT/src/scripts/checks/check-steps/01-code-formatting.sh"

test_step01_has_no_FORMAT_NIX() {
  if grep -q 'FORMAT_NIX' "$STEP01" 2>/dev/null; then
    assert_fail "Step 01 FORMAT_NIX" "Step 01 still references FORMAT_NIX"
    return 1
  fi
  assert_pass "Step 01 has no FORMAT_NIX references"
}

test_step01_has_no_format_flag() {
  if grep -q -- '--format' "$STEP01" 2>/dev/null; then
    assert_fail "Step 01 --format" "Step 01 still references --format"
    return 1
  fi
  assert_pass "Step 01 has no --format references"
}

test_step01_has_no_fail_on_change() {
  if grep -q '--fail-on-change' "$STEP01" 2>/dev/null; then
    assert_fail "Step 01 --fail-on-change" "Step 01 still uses --fail-on-change"
    return 1
  fi
  assert_pass "Step 01 has no --fail-on-change"
}

test_step01_calls_treefmt() {
  if ! grep -q '\btreefmt\b' "$STEP01" 2>/dev/null; then
    assert_fail "Step 01 treefmt" "Step 01 does not call treefmt"
    return 1
  fi
  assert_pass "Step 01 calls treefmt"
}

echo "=== Step 01 FORMAT_NIX removal tests (POSIX) ==="

test_step01_has_no_FORMAT_NIX
test_step01_has_no_format_flag
test_step01_has_no_fail_on_change
test_step01_calls_treefmt

echo "--- Step 01 POSIX tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
