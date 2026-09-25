#!/usr/bin/env bash
# Tests for the shared repository-policy.awk scan program.
#
# The program carries every pattern scan for the repo-policy steps, and the call
# sites read it through process substitution, which discards awk's exit status.
# A syntax error there kills every mode at once and prints nothing, so no step
# can notice.  These cases close both halves of that gap: the program compiles,
# and each mode still fires on a known violation.  A rule that compiles but can
# no longer fire is the failure this guard exists to catch.
#
# Run with: bash tests/scripts/check-steps/repository-policy-awk-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../test-lib.sh
. "$SCRIPT_DIR/../test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
AWK_PROGRAM="$REPO_ROOT/src/scripts/checks/check-steps/repository-policy.awk"
readonly REPO_ROOT AWK_PROGRAM

# The removed skip signal is assembled from parts: this guard's own source is
# scanned by the skip-constructs mode (the program excludes only itself), so a
# literal copy here would make the guard violate the rule it guards.
SKIP_SIGNAL='return'
readonly SKIP_SIGNAL

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# scan MODE FILE... — print the scan's stdout for MODE.  The exit status is
# discarded on purpose: the consumers are process substitutions that read only
# stdout, so the output is the only observable a rule can fire through.
scan() {
  local _mode="$1"
  shift
  if [ "$_mode" = default ]; then
    awk -f "$AWK_PROGRAM" "$@" || true
  else
    awk -v mode="$_mode" -f "$AWK_PROGRAM" "$@" || true
  fi
}

# One fixture per mode, each holding exactly one known violation.
make_fixtures() {
  # default mode: a heredoc body one line over the 30-line limit.
  {
    printf 'cat <<%s\n' "'INNER'"
    _i=0
    while [ "$_i" -lt 31 ]; do
      printf 'body line %d\n' "$_i"
      _i=$((_i + 1))
    done
    printf 'INNER\n'
  } >"$WORK_DIR/heredoc-fixture.sh"

  # logging-format mode: a backtick-e escape literal in a .ps1.
  cat >"$WORK_DIR/logging-fixture.ps1" <<'FIXTURE'
Write-Host "`e[31m"
FIXTURE

  # skip-constructs mode: the removed skip signal.
  # shellcheck disable=SC2016 # reason: $condition is a literal PowerShell variable in the emitted fixture, not a shell expansion
  printf 'if ($condition) { %s 2 }\n' "$SKIP_SIGNAL" >"$WORK_DIR/skip-fixture.ps1"
}

# The program must parse as a whole, or `-f` makes every mode exit non-zero
# before reading a single input file.
test_awk_program_compiles() {
  local _err _rc=0
  _err=$(awk -f "$AWK_PROGRAM" </dev/null 2>&1) || _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "repository-policy.awk compiles"
  else
    assert_fail "repository-policy.awk compiles" "awk exited $_rc: $_err"
  fi
}

# assert_mode_reports NAME MODE FILE EXPECTED — the rule must print a line
# carrying EXPECTED for the fixture that violates it.
assert_mode_reports() {
  local _name="$1" _mode="$2" _file="$3" _expected="$4" _out
  _out="$(scan "$_mode" "$_file")"
  if printf '%s\n' "$_out" | grep -qF -- "$_expected"; then
    assert_pass "$_name"
  else
    assert_fail "$_name" "rule did not report $_expected; output: ${_out:-<empty>}"
  fi
}

test_default_mode_reports_oversized_heredoc() {
  assert_mode_reports "default mode reports an oversized heredoc" default \
    "$WORK_DIR/heredoc-fixture.sh" "heredoc INNER has 31 content lines"
}

test_logging_format_mode_reports_backtick_e() {
  assert_mode_reports "logging-format mode reports a backtick-e escape literal" logging-format \
    "$WORK_DIR/logging-fixture.ps1" "backtick-e escape literal"
}

test_skip_constructs_mode_reports_removed_skip_signal() {
  assert_mode_reports "skip-constructs mode reports the removed skip signal" skip-constructs \
    "$WORK_DIR/skip-fixture.ps1" "removed skip mechanism '${SKIP_SIGNAL} 2'"
}

make_fixtures
test_awk_program_compiles
test_default_mode_reports_oversized_heredoc
test_logging_format_mode_reports_backtick_e
test_skip_constructs_mode_reports_removed_skip_signal
finish_tests
