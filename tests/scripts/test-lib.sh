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
  CYAN='\033[1;36m'
  # shellcheck disable=SC2034 # reason: consumed by assert_skip below and by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  CYAN=''
  # shellcheck disable=SC2034 # reason: consumed by assert_skip below and by sibling test files (gen-completions-tests.sh, nucleus-apps-smoke-tests.sh) via sourcing
  YELLOW=''
  NC=''
fi

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

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

# assert_skip — Record a test that could not run (missing optional dependency,
# unsupported host). Skips never fail the suite, but they are reported so a
# suite that quietly stopped exercising anything stays visible in the output.
assert_skip() {
  local test_name="$1"
  local reason="$2"
  printf '%s⊘%s %s: %s\n' "$YELLOW" "$NC" "$test_name" "$reason"
  ((++TESTS_SKIPPED))
}

# finish_tests — Print the tally and exit with the suite's status. Assertions only
# bump a counter, so a suite that never turns the tally into an exit status reports
# success to the runner — which sees only the exit status — no matter what it
# asserted. Must be the last statement of every suite that sources this library.
#
# The status is computed with `if` rather than `[ … ] && _status=1`: under `set -e`
# a failing && list carries its own status, which would abort the function on the
# very runs that should be tallied. `exit`, not `return`: `return` at a script's
# top level is an error bash reports to stderr and then ignores, so an early-exit
# caller would print the failure and keep running.
finish_tests() {
  local _status=0
  if [ "$TESTS_FAILED" -gt 0 ]; then
    _status=1
    printf '\n%s%d passed, %d failed%s\n' "$RED" "$TESTS_PASSED" "$TESTS_FAILED" "$NC" >&2
  elif [ "$TESTS_SKIPPED" -gt 0 ]; then
    printf '\n%s%d passed, %d skipped%s\n' "$GREEN" "$TESTS_PASSED" "$TESTS_SKIPPED" "$NC"
  else
    printf '\n%s%d passed%s\n' "$GREEN" "$TESTS_PASSED" "$NC"
  fi
  # Machine-readable tally, asserted by test step 05. A suite that exits without
  # reaching this line cannot prove it ran its assertions — the one failure its
  # exit status alone cannot express.
  printf '# nucleus-tally passed=%d failed=%d skipped=%d\n' \
    "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
  exit "$_status"
}

# require_command — Fail the suite when a provisioned prerequisite is missing.
# Skip-guards are banned (tooling-and-validation.instructions.md): a missing tool
# is a suite failure the tally has to record, not a silent pass. finish_tests
# exits, so the call is terminal even from inside a function.
require_command() { # <name> <reason>
  command -v "$1" >/dev/null 2>&1 && return 0
  assert_fail "prerequisite: $1" "$2"
  finish_tests
}

# section — Print a section header to stdout (F3, mirrors lib.sh section()).
section() { printf '\n%s=== [%s] %s ===%s\n' "$CYAN" "$1" "$2" "$NC"; }
