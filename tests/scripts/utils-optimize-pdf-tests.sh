#!/usr/bin/env bash
# Tests for do_optimize_pdf in scripts/utils.sh — the function behind the
# `nucleus-utils optimize-pdf` subcommand that the macOS "optimize PDF" Quick
# Action runs.
#
# The function's only observable effect is the Ghostscript command line it
# builds and the backup lifecycle around it, so the suite extracts the function
# and drives it against a recorder stub named `gs`:
#   * `-dPDFSETTINGS=/<preset>` is the entire point of the preset flag: drop it
#     and every call silently optimizes at the default quality, and a preset
#     that reaches gs misspelled produces a different file with the same exit
#     status, so nothing downstream notices;
#   * `-sDEVICE=pdfwrite` and `-sOutputFile=<file>` are what turn the moved
#     original into the optimized replacement, while `-dBATCH -dNOPAUSE
#     -dQUIET` keep gs non-interactive so an unattended Quick Action cannot
#     hang on a prompt;
#   * the `.bak` is the only recovery copy, so both ends of its lifecycle are
#     pinned: kept on success, removed by --rm-bak, and consumed by the restore
#     when gs fails.
#
# Every fixture, stub, and log lives in a mktemp tree. The real Ghostscript is
# never invoked and no write lands outside the tree.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

UTILS_SH="$SCRIPT_DIR/../../scripts/utils.sh"

# Fail closed: without the extracted function every case below would call an
# undefined command, and the suite would report a green tally for an optimizer
# that never ran.
OPTIMIZE_FUNC="$(extract_func do_optimize_pdf "$UTILS_SH")"
if [ -z "$OPTIMIZE_FUNC" ]; then
  assert_fail "do_optimize_pdf is defined in scripts/utils.sh" \
    "extract_func do_optimize_pdf returned nothing from $UTILS_SH"
  finish_tests
fi

eval "$OPTIMIZE_FUNC"

# ---- Helper stubs ----
#
# scripts/utils.sh gets say/warn/error/usage from src/scripts/lib/lib.sh, and
# extract_func carries over only the function under test, so the suite has to
# supply them. None of the stubs may exit: lib.sh's error() terminates the
# process, and a stub that did the same would take the suite down from inside
# the function instead of letting do_optimize_pdf return the failure status the
# error cases assert on. warn and error are recorded rather than printed so the
# suite can assert that the failure was reported to the user.
WARN_LOG=""
ERROR_LOG=""
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_optimize_pdf body
say() { :; }
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_optimize_pdf body
usage() { :; }
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_optimize_pdf body
warn() {
  if [ -n "$WARN_LOG" ]; then
    printf '%s\n' "$*" >>"$WARN_LOG"
  fi
}
# shellcheck disable=SC2329 # reason: invoked from the eval'd do_optimize_pdf body
error() {
  if [ -n "$ERROR_LOG" ]; then
    printf '%s\n' "$*" >>"$ERROR_LOG"
  fi
}

# make_gs_stub <path> <argv_log> <exit_status> <payload> — executable `gs`
# stand-in. It records the path it was invoked as plus its argv, writes
# <payload> to the path named by its own -sOutputFile= argument (a real gs
# writes the optimized PDF there), and exits with <exit_status>. Recording the
# invocation path is what shows the function ran the gs that PATH resolved.
make_gs_stub() {
  cat >"$1" <<STUB
#!/bin/sh
printf '%s\\n' "\$0 \$*" >>"$2"
for _arg in "\$@"; do
  case "\$_arg" in
  -sOutputFile=*) printf '%s\\n' "$4" >"\${_arg#-sOutputFile=}" ;;
  esac
done
exit $3
STUB
  chmod +x "$1"
}

# recorded_invocations <log> — how many invocations the recorder logged.
recorded_invocations() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0'
  fi
}

# recorded_line <log> <n> — the n-th recorded invocation, empty when absent.
recorded_line() {
  if [ -f "$1" ]; then
    sed -n "$2p" "$1"
  fi
}

# file_content <path> — the file's contents with the trailing newline dropped,
# empty when the file is missing. A missing output then reads as a mismatch
# instead of aborting the suite.
file_content() {
  if [ -f "$1" ]; then
    cat "$1"
  fi
}

# run_optimize_pdf <stub_dir> <tmpdir> <args...> — run the extracted function in
# a subshell whose PATH starts with the stub bin directory and whose TMPDIR
# points inside the case's mktemp tree. The subshell keeps both exports out of
# the suite, and the explicit TMPDIR is what stops the function's fallback to a
# per-user cache directory under HOME from writing outside the tree.
run_optimize_pdf() {
  local _stub_dir="$1" _tmpdir="$2"
  shift 2
  (
    PATH="$_stub_dir:$PATH"
    TMPDIR="$_tmpdir"
    export PATH TMPDIR
    do_optimize_pdf "$@"
  )
}

section 1 "Ghostscript command line"

test_default_preset_invokes_gs_once_with_the_documented_argv() {
  local work bin gs log pdf bak status=0 invocations recorded expected
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  pdf="$work/input.pdf"
  printf 'original-bytes\n' >"$pdf"
  bak="$pdf.bak"

  run_optimize_pdf "$bin" "$work/tmp" "$pdf" || status=$?

  invocations="$(recorded_invocations "$log")"
  if [ "$status" -eq 0 ] && [ "$invocations" = "1" ]; then
    assert_pass "default preset runs gs exactly once"
  else
    assert_fail "default preset runs gs exactly once" \
      "expected exit 0 and 1 invocation, got exit $status and $invocations invocation(s)"
  fi

  # Full-string equality, not a prefix test: the whole line is the contract,
  # including the .bak as the input argument, so a dropped or reordered flag
  # shows up as a mismatch.
  recorded="$(recorded_line "$log" 1)"
  expected="$gs -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 -dPDFSETTINGS=/default -dNOPAUSE -dQUIET -dBATCH -sOutputFile=$pdf $bak"
  if [ "$recorded" = "$expected" ]; then
    assert_pass "gs receives the documented flag set for the default preset"
  else
    assert_fail "gs receives the documented flag set for the default preset" \
      "expected [$expected], got [$recorded]"
  fi
  rm -rf "$work"
}

test_every_documented_preset_reaches_ghostscript_as_one_argv_word() {
  local work bin gs log pdf preset status actual expected
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  pdf="$work/input.pdf"

  for preset in default ebook prepress printer screen; do
    # Fresh fixture per preset: the pass before consumed the input into its
    # .bak, and leaving that .bak in place would trip the refusal guard instead
    # of exercising the preset.
    rm -f "$pdf" "$pdf.bak"
    printf 'original-bytes\n' >"$pdf"
    : >"$log"
    status=0
    run_optimize_pdf "$bin" "$work/tmp" --preset "$preset" "$pdf" || status=$?

    expected="-dPDFSETTINGS=/$preset"
    actual=""
    if [ -f "$log" ]; then
      actual="$(tr ' ' '\n' <"$log" | grep -x -F -- "$expected" || true)"
    fi
    if [ "$status" -eq 0 ] && [ "$actual" = "$expected" ]; then
      assert_pass "--preset $preset reaches gs as $expected"
    else
      assert_fail "--preset $preset reaches gs as $expected" \
        "expected exit 0 and the argv word [$expected], got exit $status and [$actual]"
    fi
  done
  rm -rf "$work"
}

test_each_input_produces_its_own_gs_invocation() {
  local work bin gs log first second status=0 invocations
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  first="$work/first.pdf"
  second="$work/second.pdf"
  printf 'original-bytes\n' >"$first"
  printf 'original-bytes\n' >"$second"

  run_optimize_pdf "$bin" "$work/tmp" "$first" "$second" || status=$?

  # A loop that stopped after the first file, or a shared command that received
  # both files, would leave one input unoptimized while still exiting 0.
  invocations="$(recorded_invocations "$log")"
  if [ "$status" -eq 0 ] && [ "$invocations" = "2" ]; then
    assert_pass "two inputs produce two gs invocations"
  else
    assert_fail "two inputs produce two gs invocations" \
      "expected exit 0 and 2 invocations, got exit $status and $invocations invocation(s)"
  fi

  if [ "$(file_content "$first")" = "optimized-by-stub" ] &&
    [ "$(file_content "$second")" = "optimized-by-stub" ]; then
    assert_pass "both inputs receive the gs output"
  else
    assert_fail "both inputs receive the gs output" \
      "expected [$first] and [$second] to hold the stub output"
  fi
  rm -rf "$work"
}

section 2 "Backup lifecycle"

test_gs_output_replaces_the_input_and_the_backup_is_kept_by_default() {
  local work bin gs log pdf bak status=0
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  pdf="$work/input.pdf"
  printf 'original-bytes\n' >"$pdf"
  bak="$pdf.bak"

  run_optimize_pdf "$bin" "$work/tmp" "$pdf" || status=$?

  # The stub writes only to the path named by -sOutputFile=, so the optimized
  # content landing at the input path is proof that gs was handed the right
  # output target — a missing -sOutputFile would leave the input empty.
  if [ "$status" -eq 0 ] && [ "$(file_content "$pdf")" = "optimized-by-stub" ]; then
    assert_pass "gs output lands at the input path on success"
  else
    assert_fail "gs output lands at the input path on success" \
      "expected exit 0 and the stub output at [$pdf], got exit $status and [$(file_content "$pdf")]"
  fi

  if [ "$(file_content "$bak")" = "original-bytes" ]; then
    assert_pass "the original is kept as .bak after a successful run"
  else
    assert_fail "the original is kept as .bak after a successful run" \
      "expected the original bytes at [$bak], got [$(file_content "$bak")]"
  fi
  rm -rf "$work"
}

test_rm_bak_removes_the_backup_after_success() {
  local work bin gs log pdf bak status=0 backup_state
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  pdf="$work/input.pdf"
  printf 'original-bytes\n' >"$pdf"
  bak="$pdf.bak"

  run_optimize_pdf "$bin" "$work/tmp" --rm-bak "$pdf" || status=$?

  backup_state="absent"
  if [ -e "$bak" ]; then
    backup_state="present"
  fi
  if [ "$status" -eq 0 ] && [ "$backup_state" = "absent" ]; then
    assert_pass "--rm-bak removes the .bak after a successful run"
  else
    assert_fail "--rm-bak removes the .bak after a successful run" \
      "expected exit 0 and no [$bak], got exit $status and a $backup_state .bak"
  fi

  if [ "$(file_content "$pdf")" = "optimized-by-stub" ]; then
    assert_pass "--rm-bak still writes the optimized output to the input path"
  else
    assert_fail "--rm-bak still writes the optimized output to the input path" \
      "expected the stub output at [$pdf], got [$(file_content "$pdf")]"
  fi
  rm -rf "$work"
}

section 3 "Failure handling"

test_unknown_preset_fails_without_invoking_ghostscript() {
  local work bin gs log pdf bak status=0 invocations
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  WARN_LOG="$work/warn.log"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"
  pdf="$work/input.pdf"
  printf 'original-bytes\n' >"$pdf"
  bak="$pdf.bak"

  run_optimize_pdf "$bin" "$work/tmp" --preset bogus "$pdf" || status=$?

  # Rejecting before the loop is the module's fail-fast contract; a validation
  # moved after the mv or after the gs call would leave the file renamed or
  # rewritten even though the preset was refused.
  invocations="$(recorded_invocations "$log")"
  if [ "$status" -ne 0 ] && [ "$invocations" = "0" ]; then
    assert_pass "an unknown preset fails before gs runs"
  else
    assert_fail "an unknown preset fails before gs runs" \
      "expected a non-zero return and 0 invocations, got exit $status and $invocations invocation(s)"
  fi

  if [ ! -e "$bak" ] && [ "$(file_content "$pdf")" = "original-bytes" ]; then
    assert_pass "an unknown preset leaves the input file untouched"
  else
    assert_fail "an unknown preset leaves the input file untouched" \
      "expected the original bytes at [$pdf] and no [$bak]"
  fi

  if grep -q -F -- "unknown preset: bogus" "$WARN_LOG" 2>/dev/null; then
    assert_pass "an unknown preset is reported to the user"
  else
    assert_fail "an unknown preset is reported to the user" \
      "no warning naming the rejected preset at [$WARN_LOG]"
  fi
  rm -rf "$work"
}

test_ghostscript_failure_restores_the_original_and_leaves_no_backup() {
  local work bin gs log pdf bak status=0 invocations errors
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  ERROR_LOG="$work/error.log"
  # The stub writes its output before exiting non-zero, so the restore has to
  # overwrite bytes that are already on disk at the input path.
  make_gs_stub "$gs" "$log" 7 "half-written-by-failed-stub"
  pdf="$work/input.pdf"
  printf 'original-bytes\n' >"$pdf"
  bak="$pdf.bak"

  run_optimize_pdf "$bin" "$work/tmp" "$pdf" || status=$?

  invocations="$(recorded_invocations "$log")"
  if [ "$status" -ne 0 ] && [ "$invocations" = "1" ]; then
    assert_pass "a failing gs fails the run"
  else
    assert_fail "a failing gs fails the run" \
      "expected a non-zero return and 1 invocation, got exit $status and $invocations invocation(s)"
  fi

  # The .bak is consumed by the restore: keeping it would leave a stale copy
  # next to the original and make the next run refuse with "backup already
  # exists".
  if [ ! -e "$bak" ] && [ "$(file_content "$pdf")" = "original-bytes" ]; then
    assert_pass "a failing gs restores the original and leaves no .bak"
  else
    assert_fail "a failing gs restores the original and leaves no .bak" \
      "expected the original bytes at [$pdf] and no [$bak], got [$(file_content "$pdf")]"
  fi

  errors="$(recorded_invocations "$ERROR_LOG")"
  if [ "$errors" = "1" ]; then
    assert_pass "a failing gs is reported to the user"
  else
    assert_fail "a failing gs is reported to the user" \
      "expected 1 error() call, got $errors"
  fi
  rm -rf "$work"
}

test_no_input_files_is_refused_before_ghostscript() {
  local work bin gs log status=0 invocations
  work="$(mktemp -d)"
  bin="$work/bin"
  mkdir -p "$bin"
  gs="$bin/gs"
  log="$work/gs.argv"
  make_gs_stub "$gs" "$log" 0 "optimized-by-stub"

  run_optimize_pdf "$bin" "$work/tmp" || status=$?

  # The Quick Action passes the selected files; an empty selection must fail
  # loudly rather than run gs with no target.
  invocations="$(recorded_invocations "$log")"
  if [ "$status" -ne 0 ] && [ "$invocations" = "0" ]; then
    assert_pass "an empty file list is refused before gs runs"
  else
    assert_fail "an empty file list is refused before gs runs" \
      "expected a non-zero return and 0 invocations, got exit $status and $invocations invocation(s)"
  fi
  rm -rf "$work"
}

# ---- Ghostscript command line ----

test_default_preset_invokes_gs_once_with_the_documented_argv
test_every_documented_preset_reaches_ghostscript_as_one_argv_word
test_each_input_produces_its_own_gs_invocation

# ---- Backup lifecycle ----

test_gs_output_replaces_the_input_and_the_backup_is_kept_by_default
test_rm_bak_removes_the_backup_after_success

# ---- Failure handling ----

test_unknown_preset_fails_without_invoking_ghostscript
test_ghostscript_failure_restores_the_original_and_leaves_no_backup
test_no_input_files_is_refused_before_ghostscript

finish_tests
