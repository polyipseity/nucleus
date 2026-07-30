#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=all
# Test: step 15 yaml-structural must output explicit skip message when no YAML files to check.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/15-yaml-structural.sh"

test_step15_has_explicit_skip() {
  if grep -q 'SKIPPED.*no YAML files' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 15 should have explicit skip message when no YAML files"
  return 1
}

test_step15_skip_before_passed() {
  local skip_line passed_line
  skip_line=$(grep -n 'SKIPPED.*no YAML files' "$TEST_FILE" | head -1 | cut -d: -f1)
  passed_line=$(grep -n 'YAML structural validation passed' "$TEST_FILE" | head -1 | cut -d: -f1)
  if [ -z "$skip_line" ]; then
    echo "FAIL: no skip message found"
    return 1
  fi
  if [ -n "$passed_line" ] && [ "$skip_line" -gt "$passed_line" ]; then
    echo "FAIL: skip message must appear before 'YAML structural validation passed'"
    return 1
  fi
  return 0
}

if [ "$#" -eq 0 ] || [ "$1" = "test_step15_has_explicit_skip" ]; then
  test_step15_has_explicit_skip || exit 1
fi
if [ "$#" -eq 0 ] || [ "$1" = "test_step15_skip_before_passed" ]; then
  test_step15_skip_before_passed || exit 1
fi
