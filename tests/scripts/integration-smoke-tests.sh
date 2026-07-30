#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=all
# Integration smoke tests for the step-runner framework.
# These run the actual check/test scripts (with --help or --scoped to limit scope).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

failures=0

test_check_help() {
  if "$REPO_ROOT/scripts/check.sh" --help > /dev/null 2>&1; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --help should exit 0"
  return 1
}

test_check_help_output() {
  local output
  output=$("$REPO_ROOT/scripts/check.sh" --help 2>&1)
  if echo "$output" | grep -q 'Usage\|--skip-steps\|--scoped'; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --help should show usage with expected flags"
  return 1
}

test_check_help_no_format() {
  local output
  output=$("$REPO_ROOT/scripts/check.sh" --help 2>&1)
  if echo "$output" | grep -qv -- '--format'; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --help should NOT contain --format"
  return 1
}

test_test_help() {
  if "$REPO_ROOT/scripts/test.sh" --help > /dev/null 2>&1; then
    return 0
  fi
  echo "FAIL: scripts/test.sh --help should exit 0"
  return 1
}

test_test_help_no_skip_system_build() {
  local output
  output=$("$REPO_ROOT/scripts/test.sh" --help 2>&1)
  if echo "$output" | grep -qv -- '--skip-system-build'; then
    return 0
  fi
  echo "FAIL: scripts/test.sh --help should NOT contain --skip-system-build"
  return 1
}

test_check_skip_steps_accepts_valid_ids() {
  if "$REPO_ROOT/scripts/check.sh" --skip-steps=code-formatting --scoped "$REPO_ROOT/src/modules/core.nix" > /dev/null 2>&1; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --skip-steps=code-formatting should exit 0"
  return 1
}

# Run all tests
echo "=== Integration smoke tests ==="
for test in test_check_help test_check_help_output test_check_help_no_format \
            test_test_help test_test_help_no_skip_system_build \
            test_check_skip_steps_accepts_valid_ids; do
  if $test; then
    echo "  ✓ $test"
  else
    echo "  ✗ $test"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "--- $failures integration test(s) failed ---"
  exit 1
fi
echo "--- All integration smoke tests passed ---"
exit 0
