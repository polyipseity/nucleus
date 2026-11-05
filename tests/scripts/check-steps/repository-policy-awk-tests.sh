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

# scan MODE FILE...: print the scan's stdout for MODE.  The exit status is
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

  # logging-format mode: prose whose inline code starts with e. The narrowed
  # pattern must leave `enable` alone while still catching a real escape.
  cat >"$WORK_DIR/logging-inline-fixture.ps1" <<'FIXTURE'
# the `enable` flag
Write-Host 'the `enable` flag'
FIXTURE

  # logging-format mode: a backtick-e that ends the line, the form the pattern's
  # `$` alternative covers. No quote follows, so no character after the e.
  cat >"$WORK_DIR/logging-tail-fixture.ps1" <<'FIXTURE'
$escape = `e
FIXTURE

  # skip-constructs mode: the removed skip signal.
  # shellcheck disable=SC2016 # reason: $condition is a literal PowerShell variable in the emitted fixture, not a shell expansion
  printf 'if ($condition) { %s 2 }\n' "$SKIP_SIGNAL" >"$WORK_DIR/skip-fixture.ps1"

  # activation-naming mode: a comment carrying a brace inside the region. The
  # comment must not count toward the depth, or the region closes before the
  # entry below and the entry is never reported.
  cat >"$WORK_DIR/activation-comment-fixture.nix" <<'FIXTURE'
home.activation = {
  # a comment with } inside the region
  probe-after = lib.hm.dag.entryAfter ["writeBoundary"] "x";
};
FIXTURE

}

# The program must parse as a whole, or `-f` makes every mode exit non-zero
# before reading a single input file.
test_awk_program_compiles() {
  local _err _rc=0
  _err=$(printf '' | awk -f "$AWK_PROGRAM" 2>&1) || _rc=$?
  if [ "$_rc" -eq 0 ]; then
    assert_pass "repository-policy.awk compiles"
  else
    assert_fail "repository-policy.awk compiles" "awk exited $_rc: $_err"
  fi
}

# assert_mode_reports NAME MODE FILE EXPECTED: the rule must print a line
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

# assert_mode_silent NAME MODE FILE EXPECTED: the rule must not print a line
# carrying EXPECTED for a file that only resembles a violation.  `scan` discards
# awk's status and stderr, so a missing fixture prints nothing and the case would
# pass for the wrong reason; the fixture is therefore required to exist.
assert_mode_silent() {
  local _name="$1" _mode="$2" _file="$3" _expected="$4" _out
  if [ ! -f "$_file" ]; then
    assert_fail "$_name" "fixture not found: $_file"
    return
  fi
  _out="$(scan "$_mode" "$_file")"
  if printf '%s\n' "$_out" | grep -qF -- "$_expected"; then
    assert_fail "$_name" "rule reported $_expected; output: $_out"
  else
    assert_pass "$_name"
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

test_logging_format_mode_allows_inline_code_starting_with_e() {
  assert_mode_silent "logging-format mode allows inline code starting with e" logging-format \
    "$WORK_DIR/logging-inline-fixture.ps1" "backtick-e escape literal"
}

test_logging_format_mode_reports_backtick_e_at_line_end() {
  assert_mode_reports "logging-format mode reports a backtick-e at end of line" logging-format \
    "$WORK_DIR/logging-tail-fixture.ps1" "backtick-e escape literal"
}

test_skip_constructs_mode_reports_removed_skip_signal() {
  assert_mode_reports "skip-constructs mode reports the removed skip signal" skip-constructs \
    "$WORK_DIR/skip-fixture.ps1" "removed skip mechanism '${SKIP_SIGNAL} 2'"
}

test_activation_naming_mode_ignores_comment_brace() {
  assert_mode_reports "activation-naming mode skips a comment brace in a region" activation-naming \
    "$WORK_DIR/activation-comment-fixture.nix" "probe-after"
}

# A bare operand shaped like name=value is an awk variable assignment, so a repo
# file literally named x=y would never be opened. The bare form is what a
# root-level file contributes to a relative path list, so the case runs from the
# fixture directory; an empty stdin pipe keeps an assignment-only operand
# list from falling through to stdin and hanging the case.
test_activation_naming_mode_reads_assignment_named_file() {
  local _out
  _out="$(cd "$REPO_ROOT/tests/fixtures" && printf '' | scan activation-naming x=y)"
  if printf '%s\n' "$_out" | grep -qF -- "probe-y"; then
    assert_pass "activation-naming mode reads a file named x=y"
  else
    assert_fail "activation-naming mode reads a file named x=y" "file was skipped; output: ${_out:-<empty>}"
  fi
}

# The discard literals live in static fixtures under tests/fixtures/log-capture-awk/: the step-12 log-capture scan excludes tests/fixtures/ (the sanctioned
# home for violation samples) but scans suite files, so the property text
# cannot be generated here. The files carry a .txt extension because the scan
# helper feeds paths straight to awk with no extension gate, while nixfmt and
# the step-03 parse scan would rewrite or reject .nix and shift the line
# coordinates these cases assert. Line 3 pins the report coordinate.
test_log_capture_mode_reports_discard_directive() {
  assert_mode_reports "log-capture mode reports a discard directive on line 3" log-capture \
    "$REPO_ROOT/tests/fixtures/log-capture-awk/discard-on-line3.txt" ":3:StandardOutPath = \""
}

# The per-file FNR==1 rule reports the previous file and resets state before
# the scan rule runs on the same line, so line 1 must still be scanned.
test_log_capture_mode_scans_directive_on_line_one() {
  assert_mode_reports "log-capture mode scans a directive on line 1" log-capture \
    "$REPO_ROOT/tests/fixtures/log-capture-awk/discard-on-line1.txt" ":1:StandardErrorPath = \""
}

make_fixtures
test_awk_program_compiles
test_default_mode_reports_oversized_heredoc
test_logging_format_mode_reports_backtick_e
test_logging_format_mode_allows_inline_code_starting_with_e
test_logging_format_mode_reports_backtick_e_at_line_end
test_skip_constructs_mode_reports_removed_skip_signal
test_activation_naming_mode_ignores_comment_brace
test_activation_naming_mode_reads_assignment_named_file
test_log_capture_mode_reports_discard_directive
test_log_capture_mode_scans_directive_on_line_one
finish_tests
