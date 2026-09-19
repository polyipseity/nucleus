#!/usr/bin/env bash
# Tests for do_strip_metadata in scripts/utils.sh — the function behind
# `nucleus-utils strip-metadata`, which the macOS "strip metadata" Quick
# Action, the NixOS file-manager integrations, and the Windows context-menu
# entries all call.
#
# The only effect the function has outside the filesystem is the message it
# hands to the platform notifier, so the suite extracts the reporting functions
# and drives them against a recorder stub named `osascript`:
#   * a Finder Quick Action discards the Run Shell Script action's stdout and
#     stderr, so the dialog is the ONLY feedback the user can see. A message the
#     user never sees is indistinguishable from a broken action, which is why
#     the aggregation contract is pinned here rather than in a terminal;
#   * one dialog per run — not one per skipped file, and not none — is the part
#     that is invisible from a shell and obvious in the GUI, so every case
#     asserts the dialog COUNT as well as its text;
#   * the report must travel as argv: spliced into the AppleScript source, a
#     path containing a quote or a backslash is a syntax error, and the
#     discarded stderr hides it;
#   * a failing input must not abandon the rest of the selection, because a
#     Quick Action hands every selected file to a single invocation.
#
# Every fixture, stub, and log lives in a mktemp tree. No real dialog,
# notification, mat2, or exiftool is invoked.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

UTILS_SH="$SCRIPT_DIR/../../scripts/utils.sh"

# Fail closed: without the extracted functions every case below would call an
# undefined command, and the suite would report a green tally for a report that
# was never built.
STRIP_FUNC="$(extract_func do_strip_metadata "$UTILS_SH")"
POPUP_FUNC="$(extract_func _popup "$UTILS_SH")"
NOTIFY_FUNC="$(extract_func _notify "$UTILS_SH")"
SUMMARY_FUNC="$(extract_func _strip_metadata_summary "$UTILS_SH")"
for _pair in \
  "do_strip_metadata:$STRIP_FUNC" \
  "_popup:$POPUP_FUNC" \
  "_notify:$NOTIFY_FUNC" \
  "_strip_metadata_summary:$SUMMARY_FUNC"; do
  if [ -z "${_pair#*:}" ]; then
    assert_fail "${_pair%%:*} is defined in scripts/utils.sh" \
      "extract_func ${_pair%%:*} returned nothing from $UTILS_SH"
    finish_tests
  fi
done

# shellcheck disable=SC2086 # reason: the extracted bodies are eval'd as source, and word splitting is the point.
eval "$STRIP_FUNC"
# shellcheck disable=SC2086 # reason: see above.
eval "$POPUP_FUNC"
# shellcheck disable=SC2086 # reason: see above.
eval "$NOTIFY_FUNC"
# shellcheck disable=SC2086 # reason: see above.
eval "$SUMMARY_FUNC"

# ---- Helper stubs ----
#
# scripts/utils.sh gets say/warn/error/usage from src/scripts/lib/lib.sh, and
# extract_func carries over only the functions under test, so the suite has to
# supply them. None of the stubs may exit: lib.sh's error() returns non-zero and
# the script runs under set -e, so do_strip_metadata reports per-input failures
# through _error_report instead of aborting. warn and error are recorded rather
# than printed so a case can assert that the failure was reported at all.
WARN_LOG=""
ERROR_LOG=""
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_strip_metadata body
say() { :; }
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_strip_metadata body
usage() { :; }
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_strip_metadata body
warn() {
  if [ -n "$WARN_LOG" ]; then
    printf '%s\n' "$*" >>"$WARN_LOG"
  fi
}
# shellcheck disable=SC2329 # reason: invoked from the eval'd _error_report stub
error() {
  if [ -n "$ERROR_LOG" ]; then
    printf '%s\n' "$*" >>"$ERROR_LOG"
  fi
}
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_strip_metadata body
_error_report() { error "$@"; }

# make_osascript_stub <path> <log> — executable `osascript` stand-in. It records
# one line per invocation: `CALL` followed by `|`-separated argv, with the final
# field always the message body. Each argument's newlines are escaped so one
# invocation stays one line — a multi-line body would otherwise spill across
# records and truncate every later assertion at its first line. The field layout
# is what lets a case assert both what the dialog says and which argv slot
# carries the paths: the difference between a body passed as an argument and
# text spliced into the AppleScript source.
make_osascript_stub() {
  cat >"$1" <<STUB
#!/bin/sh
{
  printf 'CALL'
  for _a in "\$@"; do
    _esc="\$(printf '%s' "\$_a" | sed -e 's/\$/\\n/' | tr -d '\n')"
    printf '|%s' "\$_esc"
  done
  printf '\\n'
} >>"$2"
STUB
  chmod +x "$1"
}

# make_exit_stub <path> <name> <log> <status> — executable tool stand-in that
# records its own invocation and exits with <status>.
make_exit_stub() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "$2 \$*" >>"$3"
exit $4
STUB
  chmod +x "$1"
}

# make_fixture_toolchain <bin-dir> <log-prefix> <exiftool-status> — the two
# strippers the function resolves with command -v, plus the notifier. mat2 and
# exiftool are stubs so no fixture is really rewritten. WARN_LOG/ERROR_LOG are
# pointed inside the case's tree so the extracted function's warn/error calls are
# recorded per case instead of leaking between them.
make_fixture_toolchain() {
  mkdir -p "$1"
  make_osascript_stub "$1/osascript" "$2.osascript"
  make_exit_stub "$1/mat2" mat2 "$2.tools" 0
  make_exit_stub "$1/exiftool" exiftool "$2.tools" "$3"
  WARN_LOG="$2.warnings"
  ERROR_LOG="$2.errors"
}

# make_file <path> — an input file with distinguishable content.
make_file() { printf 'fixture\n' >"$1"; }

# run_strip_metadata <bin-dir> <args...> — run the extracted function in a
# subshell whose PATH starts with the stub bin directory, so command -v resolves
# the stubs and the suite's own exports stay out of its environment.
run_strip_metadata() {
  local _bin="$1"
  shift
  (
    PATH="$_bin:$PATH"
    export PATH
    do_strip_metadata "$@"
  )
}

# dialog_count <log> — invocations that asked for a modal dialog (as opposed to
# a transient notification).
dialog_count() {
  local _n=0
  if [ -f "$1" ]; then
    # check-suppress:suppression_doc: grep exits 1 when nothing matches, which is the zero-count branch.
    _n="$(grep -c -F '|display dialog' "$1" || true)"
  fi
  printf '%s' "$_n"
}

# dialog_body <log> — the message body of the last dialog invocation, empty
# when no dialog was requested. Reading the dialog record by kind instead of by
# position keeps the assertions independent of how many notifications the same
# run also emits.
dialog_body() {
  if [ -f "$1" ]; then
    grep -F '|display dialog' "$1" | tail -n 1 | awk -F'|' '{ print $NF }'
  fi
}

# dialog_script_text <log> — the `-e` AppleScript source of the last dialog
# invocation: everything except the argv-only body.
dialog_script_text() {
  if [ -f "$1" ]; then
    grep -F '|display dialog' "$1" | tail -n 1 | awk -F'|' '{ print $2 }'
  fi
}

# notification_body <log> — the message body of the last notification
# invocation, empty when none was posted.
notification_body() {
  if [ -f "$1" ]; then
    grep -F '|display notification' "$1" | tail -n 1 | awk -F'|' '{ print $NF }'
  fi
}

# bullet_count <text> — how many list entries the report body carries.
bullet_count() {
  local _n=0
  # check-suppress:suppression_doc: grep exits 1 when nothing matches, which is the zero-count branch.
  _n="$(printf '%s' "$1" | grep -o -F '• ' | wc -l | tr -d ' ' || true)"
  printf '%s' "$_n"
}

section 1 "Aggregated dialog (--dialog)"

test_mixed_selection_reports_every_skip_in_one_dialog() {
  local work bin log status=0 body
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  make_file "$work/one.pdf"
  make_file "$work/two.pdf"
  make_file "$work/report.docx"

  run_strip_metadata "$bin" --dialog "$work/one.pdf" "$work/two.pdf" "$work/report.docx" || status=$?

  if [ "$status" -eq 0 ] && [ "$(dialog_count "$log")" = "1" ]; then
    assert_pass "a mixed selection produces exactly one dialog"
  else
    assert_fail "a mixed selection produces exactly one dialog" \
      "expected exit 0 and 1 dialog, got exit $status and $(dialog_count "$log") dialog(s)"
  fi

  body="$(dialog_body "$log")"
  case "$body" in
  *"one.pdf"*"two.pdf"*) assert_pass "the dialog lists every skipped input" ;;
  *) assert_fail "the dialog lists every skipped input" "dialog body was [$body]" ;;
  esac
  case "$body" in
  *"report.docx"*) assert_fail "the dialog omits inputs that were processed" "dialog body was [$body]" ;;
  *) assert_pass "the dialog omits inputs that were processed" ;;
  esac
  case "$body" in
  *"Stripped metadata from 1 of 3 file(s)."*) assert_pass "the dialog reports how many inputs were processed" ;;
  *) assert_fail "the dialog reports how many inputs were processed" "dialog body was [$body]" ;;
  esac
  case "$body" in
  *"Not processed (2):"*) assert_pass "the dialog counts the inputs that were not processed" ;;
  *) assert_fail "the dialog counts the inputs that were not processed" "dialog body was [$body]" ;;
  esac
  rm -rf "$work"
}

test_dialog_body_travels_as_argv_not_as_applescript_source() {
  local work bin log weird status=0 script_field body
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  # A quote and a backslash are legal in a POSIX filename and fatal in an
  # AppleScript string literal.
  weird="$work/we\"ird\\one.pdf"
  make_file "$weird"

  run_strip_metadata "$bin" --dialog "$weird" || status=$?

  if [ "$status" -eq 0 ] && [ "$(dialog_count "$log")" = "1" ]; then
    assert_pass "a path with a quote and a backslash still produces a dialog"
  else
    assert_fail "a path with a quote and a backslash still produces a dialog" \
      "expected exit 0 and 1 dialog, got exit $status and $(dialog_count "$log") dialog(s)"
  fi

  # Field 2 is the display-dialog script text; the path must not appear there.
  script_field="$(dialog_script_text "$log")"
  case "$script_field" in
  *'we"ird\one.pdf'*) assert_fail "the path is not spliced into the AppleScript source" "script text was [$script_field]" ;;
  *) assert_pass "the path is not spliced into the AppleScript source" ;;
  esac
  body="$(dialog_body "$log")"
  case "$body" in
  *'we"ird\one.pdf'*) assert_pass "the path arrives intact in the dialog body" ;;
  *) assert_fail "the path arrives intact in the dialog body" "dialog body was [$body]" ;;
  esac
  rm -rf "$work"
}

test_report_is_capped_with_a_count_of_the_remainder() {
  local work bin log status=0 body i bullets=0 args=()
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  for i in $(seq 1 12); do
    make_file "$work/input$i.pdf"
    args+=("$work/input$i.pdf")
  done

  run_strip_metadata "$bin" --dialog "${args[@]}" || status=$?

  body="$(dialog_body "$log")"
  bullets="$(bullet_count "$body")"
  if [ "$status" -eq 0 ] && [ "$bullets" = "10" ]; then
    assert_pass "the dialog caps the listed inputs at 10"
  else
    assert_fail "the dialog caps the listed inputs at 10" \
      "expected exit 0 and 10 bullets, got exit $status and $bullets bullet(s)"
  fi
  case "$body" in
  *"... and 2 more."*) assert_pass "the dialog reports the number of inputs left out of the list" ;;
  *) assert_fail "the dialog reports the number of inputs left out of the list" "dialog body was [$body]" ;;
  esac
  rm -rf "$work"
}

test_nothing_skipped_shows_no_dialog() {
  local work bin log status=0
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  make_file "$work/report.docx"

  run_strip_metadata "$bin" --dialog "$work/report.docx" || status=$?

  # A success notification is still sent; what must not happen is a dialog.
  if [ "$status" -eq 0 ] && [ "$(dialog_count "$log")" = "0" ]; then
    assert_pass "a run with nothing skipped shows no dialog"
  else
    assert_fail "a run with nothing skipped shows no dialog" \
      "expected exit 0 and 0 dialogs, got exit $status and $(dialog_count "$log") dialog(s)"
  fi
  rm -rf "$work"
}

section 2 "Notification-only path (no --dialog)"

test_without_dialog_the_skip_is_notified_per_input_and_no_dialog_appears() {
  local work bin log status=0 body
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  make_file "$work/one.pdf"

  run_strip_metadata "$bin" "$work/one.pdf" || status=$?

  if [ "$status" -eq 0 ] && [ "$(dialog_count "$log")" = "0" ]; then
    assert_pass "the CLI path shows no dialog"
  else
    assert_fail "the CLI path shows no dialog" \
      "expected exit 0 and 0 dialogs, got exit $status and $(dialog_count "$log") dialog(s)"
  fi
  body="$(notification_body "$log")"
  case "$body" in
  *"Skipped PDF (not supported)"*) assert_pass "the CLI path still notifies about the skipped input" ;;
  *) assert_fail "the CLI path still notifies about the skipped input" "notification body was [$body]" ;;
  esac
  rm -rf "$work"
}

section 3 "Failure handling"

test_failing_input_does_not_abandon_the_remaining_files() {
  local work bin log status=0 body
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  # exiftool fails: the first input cannot be stripped.
  make_fixture_toolchain "$bin" "$work/log" 1
  make_file "$work/broken.jpg"
  make_file "$work/one.pdf"

  run_strip_metadata "$bin" --dialog "$work/broken.jpg" "$work/one.pdf" || status=$?

  if [ "$status" -eq 1 ]; then
    assert_pass "a failing input makes the run exit non-zero"
  else
    assert_fail "a failing input makes the run exit non-zero" "expected exit 1, got exit $status"
  fi
  body="$(dialog_body "$log")"
  case "$body" in
  *"broken.jpg"*) assert_pass "the failed input is reported" ;;
  *) assert_fail "the failed input is reported" "dialog body was [$body]" ;;
  esac
  # Reaching the second entry is the point: with the per-file loop this replaces,
  # the failure ended the run and the PDF was never reported at all.
  case "$body" in
  *"one.pdf"*) assert_pass "the input after the failure is still processed and reported" ;;
  *) assert_fail "the input after the failure is still processed and reported" "dialog body was [$body]" ;;
  esac
  rm -rf "$work"
}

test_refused_input_is_reported_instead_of_silently_skipped() {
  local work bin log status=0 body
  work="$(mktemp -d)"
  bin="$work/bin"
  log="$work/log.osascript"
  make_fixture_toolchain "$bin" "$work/log" 0
  make_file "$work/report.docx"
  make_file "$work/report.docx.bak"

  run_strip_metadata "$bin" --dialog "$work/report.docx" || status=$?

  if [ "$status" -eq 1 ]; then
    assert_pass "a refused input makes the run exit non-zero"
  else
    assert_fail "a refused input makes the run exit non-zero" "expected exit 1, got exit $status"
  fi
  if [ "$(dialog_count "$log")" = "1" ]; then
    assert_pass "a refused input is surfaced in the dialog"
  else
    assert_fail "a refused input is surfaced in the dialog" \
      "expected 1 dialog, got $(dialog_count "$log") dialog(s)"
  fi
  body="$(dialog_body "$log")"
  case "$body" in
  *".bak backup already exists"*) assert_pass "the dialog explains why the input was refused" ;;
  *) assert_fail "the dialog explains why the input was refused" "dialog body was [$body]" ;;
  esac
  if [ -s "$ERROR_LOG" ]; then
    assert_pass "the refusal is also reported at error severity on stderr"
  else
    assert_fail "the refusal is also reported at error severity on stderr" "no error was reported"
  fi
  rm -rf "$work"
}

# ---- Aggregated dialog (--dialog) ----

test_mixed_selection_reports_every_skip_in_one_dialog
test_dialog_body_travels_as_argv_not_as_applescript_source
test_report_is_capped_with_a_count_of_the_remainder
test_nothing_skipped_shows_no_dialog

# ---- Notification-only path (no --dialog) ----

test_without_dialog_the_skip_is_notified_per_input_and_no_dialog_appears

# ---- Failure handling ----

test_failing_input_does_not_abandon_the_remaining_files
test_refused_input_is_reported_instead_of_silently_skipped

finish_tests
