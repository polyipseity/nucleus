#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=all
# Test: step 17 suppression-audit must output explicit skip when no script files to check.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/17-suppression-audit.sh"

test_step17_has_explicit_skip() {
  if grep -q 'SKIPPED.*no script files' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should have explicit skip message when no script files"
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step17_has_explicit_skip" ]; then
  test_step17_has_explicit_skip || exit 1
fi
