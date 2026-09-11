#!/usr/bin/env bash
# Tests for src/scripts/configs/write-method1-symlink-manifest.sh — the writer that
# publishes the step-19 candidate list.
#
# Contract: the manifest is a plain file (not a store symlink) whose lines are
# absolute paths, rewritten atomically on every apply; a relative entry is refused
# so the consumer's walk can never depend on the caller's working directory.
#
# Run with: bash tests/scripts/write-method1-symlink-manifest-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
WRITER="$REPO_ROOT/src/scripts/configs/write-method1-symlink-manifest.sh"
JQ_BIN="$(command -v jq)"
readonly WRITER JQ_BIN

test_writes_header_and_every_path() {
  local tmp json out rc=0
  tmp="$(mktemp -d)"
  json="[\"$tmp/one\",\"$tmp/two with space\"]"
  out="$tmp/nested/dir/method1-symlink-manifest.txt"
  bash "$WRITER" "$out" "$json" "$JQ_BIN" >"$tmp/log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    assert_fail "writer creates parent directories and writes every path" "rc=$rc output=[$(cat "$tmp/log")]"
  elif [ ! -f "$out" ]; then
    assert_fail "writer creates parent directories and writes every path" "no manifest at $out"
  elif [ "$(grep -c '^# ' "$out")" -lt 1 ]; then
    assert_fail "writer creates parent directories and writes every path" "manifest has no comment header"
  elif [ "$(grep -vc '^#' "$out")" -ne 2 ]; then
    assert_fail "writer creates parent directories and writes every path" "expected 2 path lines, got $(grep -vc '^#' "$out")"
  elif ! grep -qxF "$tmp/two with space" "$out"; then
    assert_fail "writer creates parent directories and writes every path" "path with a space was not written verbatim"
  else
    assert_pass "writer creates parent directories and writes every path"
  fi
  rm -rf "$tmp"
}

test_relative_entry_is_refused() {
  local tmp json out rc=0
  tmp="$(mktemp -d)"
  json='["relative/path"]'
  out="$tmp/manifest.txt"
  bash "$WRITER" "$out" "$json" "$JQ_BIN" >"$tmp/log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -f "$out" ] && grep -q "not an absolute path" "$tmp/log"; then
    assert_pass "writer refuses a relative entry and writes nothing"
  else
    assert_fail "writer refuses a relative entry and writes nothing" "rc=$rc exists=$([ -f "$out" ] && echo yes || echo no) output=[$(cat "$tmp/log")]"
  fi
  rm -rf "$tmp"
}

test_rewrite_is_idempotent() {
  local tmp json first second
  tmp="$(mktemp -d)"
  json="[\"$tmp/a\",\"$tmp/b\"]"
  bash "$WRITER" "$tmp/m.txt" "$json" "$JQ_BIN" >/dev/null 2>&1
  cp "$tmp/m.txt" "$tmp/first"
  bash "$WRITER" "$tmp/m.txt" "$json" "$JQ_BIN" >/dev/null 2>&1
  first="$(cat "$tmp/first")"
  second="$(cat "$tmp/m.txt")"
  if [ "$first" = "$second" ]; then
    assert_pass "writer produces byte-identical output when nothing changed"
  else
    assert_fail "writer produces byte-identical output when nothing changed" "second run differs"
  fi
  rm -rf "$tmp"
}

test_writes_header_and_every_path
test_relative_entry_is_refused
test_rewrite_is_idempotent
finish_tests
