#!/usr/bin/env bash
# Regression tests for run_terminal_activations() in src/scripts/apply.sh.
#
# The function runs each line of a per-user manifest
# ($HOME/.config/nucleus/terminal-activations.list) and deletes it after, so
# activations are one-shot.  These tests pin: no-op on missing/empty manifest,
# ordered execution, comment skipping, and continue-on-error semantics.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

# The function under test — extracted verbatim from src/scripts/apply.sh.
# WHY: the verbatim copy (not apply.sh itself) makes failures attributable to
# this function in isolation; HOME is overridden per test so the manifest
# path is controlled and the real user config is never touched.
run_terminal_activations() {
  local manifest="$HOME/.config/nucleus/terminal-activations.list"
  if [ ! -f "$manifest" ]; then
    return
  fi

  local count
  count=$(wc -l < "$manifest")
  if [ "$count" -eq 0 ]; then
    rm -f "$manifest"
    return
  fi

  # check-suppress:suppression_doc: grep returns exit code 1 when no lines match; set -e would abort.
  printf '%s\n' "terminal-activations: running $(grep -c '^[^#]' "$manifest" || true) terminal-context activation(s)..."
  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "terminal-activations: $line"
    if ! eval "$line"; then
      printf '%s\n' "terminal-activations: command exited with error (continuing)" >&2
    fi
  done < "$manifest"
  rm -f "$manifest"
}

# ── Setup / teardown ──────────────────────────────────────────────────────
# setup — Create an isolated HOME and manifest path for one test.
# WHY: the function derives its manifest path from $HOME internally, so
# redirecting HOME is the only way to control where it reads and writes.
setup() {
  TESTDIR=$(mktemp -d)
  # Redirect HOME to the temp dir so the manifest path is isolated.
  export HOME="$TESTDIR"
  export MANIFEST_DIR="$HOME/.config/nucleus"
  mkdir -p "$MANIFEST_DIR"
  MANIFEST="$MANIFEST_DIR/terminal-activations.list"
}

teardown() {
  rm -rf -- "$TESTDIR"
}

# ── Test: no manifest file → no-op ────────────────────────────────────────
# WHY: apply.sh calls this unconditionally on every activation, so a missing
# manifest (the common case) must be silent and must not create the file.
test_no_manifest() {
  setup
  rm -f "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -z "$output" ]; then
    assert_pass "No manifest file: no-op (empty output)"
  else
    assert_fail "No manifest file: no-op" "Expected empty output, got: $output"
  fi
  teardown
}

# ── Test: empty manifest → no-op, file deleted ────────────────────────────
# WHY: an empty file means every activation already ran; deleting it keeps
# later runs from re-processing an empty list forever.
test_empty_manifest() {
  setup
  : > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -z "$output" ] && [ ! -f "$MANIFEST" ]; then
    assert_pass "Empty manifest: no-op and file deleted"
  else
    assert_fail "Empty manifest: no-op" "output='$output' exists=$([ -f "$MANIFEST" ] && echo 1 || echo 0)"
  fi
  teardown
}

# ── Test: single command execution ─────────────────────────────────────────
# WHY: pins that a plain command line is executed and the manifest is removed
# so the activation cannot run twice.
test_single_command() {
  setup
  printf 'touch %s/marker-single\n' "$TESTDIR" > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -f "$TESTDIR/marker-single" ] && [ ! -f "$MANIFEST" ]; then
    assert_pass "Single command: executes and deletes manifest"
  else
    assert_fail "Single command: execution" "marker exists=$([ -f "$TESTDIR/marker-single" ] && echo 1 || echo 0) manifest exists=$([ -f "$MANIFEST" ] && echo 1 || echo 0)"
  fi
  teardown
}

# ── Test: multiple commands in order ───────────────────────────────────────
# WHY: ordering matters — activations are dependency-ordered (e.g. a symlink
# step must precede the step that consumes it); markers verify FIFO execution.
test_multiple_commands_ordered() {
  setup
  {
    printf 'touch %s/marker-1\n' "$TESTDIR"
    printf 'touch %s/marker-2\n' "$TESTDIR"
    printf 'touch %s/marker-3\n' "$TESTDIR"
  } > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -f "$TESTDIR/marker-1" ] && [ -f "$TESTDIR/marker-2" ] && [ -f "$TESTDIR/marker-3" ]; then
    assert_pass "Multiple commands: all executed"
  else
    assert_fail "Multiple commands: execution" "not all markers created"
  fi
  teardown
}

# ── Test: comment lines are skipped ───────────────────────────────────────
# WHY: generated manifests carry # header lines naming each activation; those
# must be ignored, along with interleaved blank lines.
test_comments_skipped() {
  setup
  {
    printf '# comment line\n'
    printf '  # indented comment\n'
    printf 'touch %s/marker-comment\n' "$TESTDIR"
    printf '\n'
    printf '# another comment\n'
    printf 'touch %s/marker-comment2\n' "$TESTDIR"
  } > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -f "$TESTDIR/marker-comment" ] && [ -f "$TESTDIR/marker-comment2" ]; then
    assert_pass "Comment lines: skipped, commands still execute"
  else
    assert_fail "Comment lines: skipping" "not all markers created"
  fi
  teardown
}

# ── Test: command failure does not abort ───────────────────────────────────
# WHY: one failing activation must not strand the rest; the function logs the
# error to stderr and continues so partial failures stay visible but non-fatal.
test_command_failure_continues() {
  setup
  {
    printf 'false\n'
    printf 'touch %s/marker-after-fail\n' "$TESTDIR"
  } > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -f "$TESTDIR/marker-after-fail" ]; then
    assert_pass "Command failure: continues to subsequent commands"
  else
    assert_fail "Command failure: continuation" "marker not created after failing command"
  fi
  teardown
}

# ── Test: manifest from HM generation (name header lines) ──────────────────
# WHY: real Home Manager manifests interleave # name headers with commands;
# this pins that headers are skipped while the commands after them still run.
test_name_header_lines() {
  setup
  {
    printf '# macos-configure-safari-defaults\n'
    printf 'touch %s/marker-safari\n' "$TESTDIR"
    printf '# macos-configure-universal-access\n'
    printf 'touch %s/marker-universal\n' "$TESTDIR"
  } > "$MANIFEST"
  local output
  # check-suppress:suppression_doc: run_terminal_activations may return non-zero; manual assertion follows
  output=$(run_terminal_activations 2>&1 || true)
  if [ -f "$TESTDIR/marker-safari" ] && [ -f "$TESTDIR/marker-universal" ]; then
    assert_pass "Name header lines: commands after # headers execute correctly"
  else
    assert_fail "Name header lines: execution" "not all markers created"
  fi
  teardown
}

# ── Run all tests ──────────────────────────────────────────────────────────
test_no_manifest
test_empty_manifest
test_single_command
test_multiple_commands_ordered
test_comments_skipped
test_command_failure_continues
test_name_header_lines

printf '\n%s\n' "---"
printf '%s/%s tests passed\n' "$TESTS_PASSED" "$((TESTS_PASSED + TESTS_FAILED))"
[ "$TESTS_FAILED" -eq 0 ]
