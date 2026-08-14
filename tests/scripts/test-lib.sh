#!/usr/bin/env bash
# Shared test library: counters, assertions, and color helpers.
# Source this after setting SCRIPT_DIR and/or REPO_ROOT.

# Console color detection (mirrors lib.sh _nuc_color_init): NO_COLOR set
# non-empty -> plain; FORCE_COLOR set and != "0" or CLICOLOR_FORCE set
# non-empty -> color; else color only when stdout is a tty ([ -t 1 ]) and
# TERM != dumb. Colors become empty strings when off so assert_* can print
# plain text with plain printf (no escape interpretation).
if [ -n "${NO_COLOR-}" ]; then
  TEST_COLOR=0
elif [ -n "${CLICOLOR_FORCE-}" ] || { [ -n "${FORCE_COLOR-}" ] && [ "$FORCE_COLOR" != "0" ]; }; then
  TEST_COLOR=1
else
  TEST_COLOR=0
  case "${TERM-}" in
  dumb) ;;
  *) [ -t 1 ] && TEST_COLOR=1 ;;
  esac
fi

if [ "$TEST_COLOR" -eq 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  # shellcheck disable=SC2034 # reason: consumed by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  # shellcheck disable=SC2034 # reason: consumed by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW=''
  NC=''
fi

TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
  local test_name="$1"
  if [ "$TEST_COLOR" -eq 1 ]; then
    printf '%s✓%s %s\n' "$GREEN" "$NC" "$test_name"
  else
    echo "✓ $test_name"
  fi
  ((++TESTS_PASSED))
}

assert_fail() {
  local test_name="$1"
  local reason="$2"
  if [ "$TEST_COLOR" -eq 1 ]; then
    printf '%s✗%s %s: %s\n' "$RED" "$NC" "$test_name" "$reason"
  else
    echo "✗ $test_name: $reason"
  fi
  ((++TESTS_FAILED))
}
