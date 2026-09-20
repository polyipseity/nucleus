#!/usr/bin/env bash
# Tests for the help and missing-input paths of the four grouped PowerShell
# entry points — scripts/utils.ps1, ai.ps1, svc.ps1, vm.ps1 — the Windows twins
# of scripts/<name>.sh.
#
# Why a bash suite drives pwsh: the contract is "the two platforms answer the
# same invocation the same way", so the twin that runs everywhere (the .sh one)
# is the reference and the suite compares the two directly. tests/scripts/
# gen-completions-tests.sh already drives pwsh the same way.
#
# Three behaviours are pinned, all of them invisible from the source alone:
#   * `-Help` (and `-h`) must print the help block to stdout, write NOTHING to
#     stderr and exit 0. Get-Help only finds a script's comment-based help when
#     the help block is the first thing in the file, so a leading `#!` line — or
#     a missing-action error raised before Get-Help runs — silently degrades the
#     request to the bare syntax line. Section 1 and section 4 cover both.
#   * A bare invocation must carry the twin's severity: utils/ai print a usage
#     summary and exit 0 (asking which subcommand to run is not a failure),
#     svc/vm report a missing action and exit 1 (their callers act on the result
#     of an operation, so a run that did nothing must not read as success).
#     Write-NucleusError prints through Write-Error, which stays non-terminating
#     inside the output module, so svc/vm need an explicit exit status; section 2
#     asserts the status rather than trusting the preference.
#   * The action lists the two platforms report must be the same list. Section 3
#     feeds the twin's own message back in as the expectation, so the shared
#     wording cannot drift apart one script at a time.
#
# Every case runs the real script through pwsh; nothing is stubbed, and no
# Windows-only path is reached (all four exit or print before platform init).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

cd "$REPO_ROOT"

require_command pwsh "script-help: the PowerShell entry points under test"

# Subcommands each entry point advertises on its no-argument path. They are the
# ones the .sh twin prints; section 3 re-reads the twin, so a subcommand added
# there and not here shows up as a parity failure instead of going unnoticed.
UTILS_SUBCOMMANDS=(optimize-pdf strip-metadata)
AI_SUBCOMMANDS=(sync list status endpoint config)

_PS_OUT="$(mktemp)"
_PS_ERR="$(mktemp)"
trap 'rm -f "$_PS_OUT" "$_PS_ERR"' EXIT

# run_ps <script> [args...] — run one entry point through pwsh, capturing stdout
# into PS_STDOUT, stderr into PS_STDERR and the status into PS_EXIT. Arguments
# are pwsh parameter tokens (switches) and are passed unquoted, as a caller would
# type them: a quoted '-Help' binds as a positional string, not as a parameter.
run_ps() {
  local _script="$1"
  shift
  local _command="& '$SCRIPTS_DIR/$_script'"
  local _arg
  for _arg in "$@"; do
    _command="$_command $_arg"
  done
  PS_EXIT=0
  pwsh -NoLogo -NoProfile -NonInteractive -Command "$_command" >"$_PS_OUT" 2>"$_PS_ERR" || PS_EXIT=$?
  PS_STDOUT="$(cat "$_PS_OUT")"
  PS_STDERR="$(cat "$_PS_ERR")"
}

# run_sh <script> — run the .sh twin the same way (SH_STDOUT/SH_STDERR/SH_EXIT).
run_sh() {
  local _script="$1"
  SH_EXIT=0
  bash "$SCRIPTS_DIR/$_script" >"$_PS_OUT" 2>"$_PS_ERR" || SH_EXIT=$?
  SH_STDOUT="$(cat "$_PS_OUT")"
  SH_STDERR="$(cat "$_PS_ERR")"
}

# one_line — flatten a rendered PowerShell error record into one clean line.
# Write-Error wraps its message at the console width, indents the continuation and
# paints the text with ANSI colours, so the action list has to be unwrapped before
# it can be compared with the twin's single-line message. The pipe is thrown away
# because a wrapped line carries a `|` gutter character that is not part of the
# message (no action name contains one).
one_line() {
  sed -E $'s/\x1b\\[[0-9;]*m//g' | tr -d '\r' | tr '\n' ' ' | tr -d '|' | tr -s ' '
}

# action_list — print the action list of a "missing action" error line, or
# nothing when the text does not carry one. Matched on the "error:" prefix: a
# thrown PowerShell error record also echoes the offending source line, whose
# truncated copy of the message has no closing parenthesis and would otherwise
# swallow the real one. The last match wins for the same reason.
action_list() {
  grep -oE 'error: missing action \([^)]*\)' | tail -1 |
    sed -E 's/^error: missing action \((.*)\)$/\1/' || printf ''
}

# subcommands_for <script> — the subcommand list this entry point advertises.
subcommands_for() {
  case "$1" in
  utils) printf '%s\n' "${UTILS_SUBCOMMANDS[@]}" ;;
  ai) printf '%s\n' "${AI_SUBCOMMANDS[@]}" ;;
  *) printf '' ;;
  esac
}

# stderr_carries_error — true when a captured stderr holds an error line. The
# prefix a message carries is not asserted: the output module derives it from
# the calling file's path (a separate concern this suite does not own).
stderr_carries_error() {
  grep -qE 'error:|missing action|missing subcommand' <<<"$1"
}

section 1 "-Help prints the help block, exits 0, and stays off stderr"
for _script in utils ai svc vm; do
  run_ps "$_script.ps1" -Help
  if [ "$PS_EXIT" -eq 0 ]; then
    assert_pass "$_script.ps1 -Help: exits 0"
  else
    assert_fail "$_script.ps1 -Help: exit status" "expected 0, got $PS_EXIT"
  fi
  # SYNOPSIS and REMARKS are the headings Get-Help emits for the comment-based
  # help block (-Detailed renders .NOTES as REMARKS); the degraded form -- a bare
  # syntax line, which is what a leading `#!` line or a missing-action error
  # produces -- carries neither. Measured by prepending a shebang to ai.ps1:
  # 108 bytes, no SYNOPSIS, no REMARKS.
  if grep -q '^SYNOPSIS' <<<"$PS_STDOUT" &&
    grep -q '^REMARKS' <<<"$PS_STDOUT" &&
    grep -qF "$_script.ps1" <<<"$PS_STDOUT"; then
    assert_pass "$_script.ps1 -Help: prints the help block on stdout"
  else
    assert_fail "$_script.ps1 -Help: stdout contract" \
      "expected a SYNOPSIS block naming $_script.ps1, got $(printf '%s' "$PS_STDOUT" | wc -c) bytes"
  fi
  if stderr_carries_error "$PS_STDERR"; then
    assert_fail "$_script.ps1 -Help: stderr contract" \
      "help request wrote: $(printf '%s' "$PS_STDERR" | one_line | cut -c1-120)"
  else
    assert_pass "$_script.ps1 -Help: nothing on stderr"
  fi
done

# The bundled alias has to reach the same branch, not a subcommand named "h".
run_ps utils.ps1 -h
if [ "$PS_EXIT" -eq 0 ] && grep -q '^SYNOPSIS' <<<"$PS_STDOUT" && ! stderr_carries_error "$PS_STDERR"; then
  assert_pass "utils.ps1 -h: alias behaves like -Help"
else
  assert_fail "utils.ps1 -h: alias" "exit=$PS_EXIT stderr=$(printf '%s' "$PS_STDERR" | one_line | cut -c1-80)"
fi

section 2 "A bare invocation carries the twin's severity"
for _script in utils ai; do
  run_ps "$_script.ps1"
  if [ "$PS_EXIT" -eq 0 ]; then
    assert_pass "$_script.ps1 (no action): exits 0"
  else
    assert_fail "$_script.ps1 (no action): exit status" "expected 0, got $PS_EXIT"
  fi
  if grep -qF "usage: $_script.ps1 " <<<"$PS_STDOUT"; then
    assert_pass "$_script.ps1 (no action): prints the usage summary on stdout"
  else
    assert_fail "$_script.ps1 (no action): usage summary" "stdout did not name $_script.ps1: $(printf '%s' "$PS_STDOUT" | head -1 | cut -c1-100)"
  fi
  if stderr_carries_error "$PS_STDERR"; then
    assert_fail "$_script.ps1 (no action): stderr contract" \
      "wrote: $(printf '%s' "$PS_STDERR" | one_line | cut -c1-120)"
  else
    assert_pass "$_script.ps1 (no action): nothing on stderr"
  fi
done

for _script in svc vm; do
  run_ps "$_script.ps1"
  if [ "$PS_EXIT" -eq 1 ]; then
    assert_pass "$_script.ps1 (no action): exits 1"
  else
    assert_fail "$_script.ps1 (no action): exit status" "expected 1, got $PS_EXIT"
  fi
  # The twin prints the error and nothing else; a help dump here would make a
  # run that performed no operation read as an answered request.
  if [ -z "$PS_STDOUT" ]; then
    assert_pass "$_script.ps1 (no action): no help on stdout"
  else
    assert_fail "$_script.ps1 (no action): stdout contract" "expected no stdout, got $(printf '%s' "$PS_STDOUT" | head -1 | cut -c1-100)"
  fi
  if printf '%s' "$PS_STDERR" | one_line | action_list | grep -q .; then
    assert_pass "$_script.ps1 (no action): reports the missing action on stderr"
  else
    assert_fail "$_script.ps1 (no action): error message" "no 'missing action (...)' on stderr"
  fi
done

section 3 "Both platforms report the same action list"
for _script in svc vm; do
  run_sh "$_script.sh"
  SH_LIST="$(printf '%s' "$SH_STDERR" | action_list)"
  SH_STATUS="$SH_EXIT"
  run_ps "$_script.ps1"
  PS_LIST="$(printf '%s' "$PS_STDERR" | one_line | action_list)"
  if [ -n "$SH_LIST" ] && [ "$SH_LIST" = "$PS_LIST" ]; then
    assert_pass "$_script: missing-action list matches $_script.sh"
  else
    assert_fail "$_script: missing-action parity" "sh=[$SH_LIST] ps=[$PS_LIST]"
  fi
  if [ "$SH_STATUS" -eq "$PS_EXIT" ]; then
    assert_pass "$_script: exit status matches $_script.sh ($SH_STATUS)"
  else
    assert_fail "$_script: exit status parity" "$_script.sh=$SH_STATUS $_script.ps1=$PS_EXIT"
  fi
done

for _script in utils ai; do
  run_sh "$_script.sh"
  SH_STATUS="$SH_EXIT"
  SH_MISSING=""
  for _sub in $(subcommands_for "$_script"); do
    if ! grep -qF "$_sub" <<<"$SH_STDOUT"; then
      SH_MISSING="$SH_MISSING $_sub"
    fi
  done
  if [ -z "$SH_MISSING" ]; then
    assert_pass "$_script.sh: usage summary lists every subcommand"
  else
    # A subcommand added to the script but not to this suite's list would make
    # the parity check below pass on a stale expectation.
    assert_fail "$_script.sh: usage summary" "missing from the twin:${SH_MISSING}"
  fi

  run_ps "$_script.ps1"
  PS_MISSING=""
  for _sub in $(subcommands_for "$_script"); do
    if ! grep -qF "$_sub" <<<"$PS_STDOUT"; then
      PS_MISSING="$PS_MISSING $_sub"
    fi
  done
  if [ -z "$PS_MISSING" ]; then
    assert_pass "$_script.ps1: usage summary lists every subcommand"
  else
    assert_fail "$_script.ps1: usage summary" "missing:${PS_MISSING}"
  fi
  if [ "$SH_STATUS" -eq "$PS_EXIT" ]; then
    assert_pass "$_script: exit status matches $_script.sh ($SH_STATUS)"
  else
    assert_fail "$_script: exit status parity" "$_script.sh=$SH_STATUS $_script.ps1=$PS_EXIT"
  fi
done

section 4 "every entry point keeps its help block first in the file"
# WHY: Get-Help finds a script's comment-based help only when the help block
# opens the file. utils.ps1 carried a `#!/usr/bin/env pwsh` line -- the only .ps1
# shebang in the repo, on a file the repo keeps non-executed -- and that one line
# was enough to reduce -Help to the bare syntax line. Pinned for all four so
# re-adding such a line fails with the cause instead of with a puzzling
# "no REMARKS" from section 1.
for _script in utils ai svc vm; do
  _first_line="$(head -1 "$SCRIPTS_DIR/$_script.ps1" | tr -d '\r')"
  if [ "$_first_line" = '<#' ]; then
    assert_pass "$_script.ps1: comment-based help block is the first line"
  else
    assert_fail "$_script.ps1: help block placement" "first line is '$_first_line'"
  fi
done

finish_tests
