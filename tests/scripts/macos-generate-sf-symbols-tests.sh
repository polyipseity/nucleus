#!/usr/bin/env bash
# Tests for macos-generate-sf-symbols.sh — the SF Symbols name list generator.
#
# The generator is macOS-only, so most cases drive it with a fake `plutil` that
# emits fixture names (public + private bundles, including the private bundle's
# internal hex-ID placeholders). The cases assert the generator's output is
# names only, sorted, unique, and written to the USER root's state dir, and that
# the sf-symbols skill and the activation entry point at the generated file.
#
# Host-agnostic: the fake plutil plus the real grep/sort/cmp run on every host.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

init_test_state

REPO_ROOT="$SCRIPT_DIR/../.."
GENERATOR="$REPO_ROOT/src/platforms/macOS/scripts/macos-generate-sf-symbols.sh"
SKILL_MD="$REPO_ROOT/.agents/skills/sf-symbols/SKILL.md"
COMMITTED_LIST="$REPO_ROOT/.agents/skills/sf-symbols/symbols.txt"
MODULE_NIX="$REPO_ROOT/src/platforms/macOS/modules/default.nix"

GREP_BIN="$(command -v grep)"
SORT_BIN="$(command -v sort)"
CMP_BIN="$(command -v cmp)"

OUT="$NUCLEUS_USER_ROOT/state/sf-symbols.txt"

# --- fake plutil: fixture names for `plutil -extract symbols raw -o - <plist>` --
_fake_bin_dir="$(mktemp -d)"
cat >"$_fake_bin_dir/plutil" <<'FAKE_PLUTIL'
#!/bin/sh
# Emits the fixture keys for `plutil -extract symbols raw -o - <plist>`. The
# plist path selects the bundle. The private fixture carries the internal hex-ID
# placeholders that the generator must filter out.
set -eu
mode=""
for _a in "$@"; do
  case "$_a" in
  *CoreGlyphsPrivate*) mode="private" ;;
  *CoreGlyphs.bundle*) mode="public" ;;
  esac
done
case "$mode" in
public)
  printf '%s\n' "square.and.arrow.up" "0.circle" "zzz"
  ;;
private)
  printf '%s\n' "2F45143C03184F9D85936BB967922E8F" \
    "0828E54B965E418AB42353CA91BFBBEE.chargingcase" \
    "accessibility.page" "square.and.arrow.up"
  ;;
*)
  echo "fake plutil: unknown plist" >&2
  exit 1
  ;;
esac
FAKE_PLUTIL
chmod +x "$_fake_bin_dir/plutil"
trap 'rm -rf "$_fake_bin_dir"' EXIT

_run_generator() {
  "$GENERATOR" "$_fake_bin_dir/plutil" "$GREP_BIN" "$SORT_BIN" "$CMP_BIN"
}

# --- Tests ---

test_output_is_names_only() {
  section 1 "output is names only, sorted, unique"

  rm -f "$OUT"
  _run_generator

  if [ -f "$OUT" ]; then
    assert_pass "generator wrote $OUT"
  else
    assert_fail "generator output file" "expected $OUT to exist"
    return
  fi

  local expected
  expected="$(printf '%s\n' 0.circle accessibility.page square.and.arrow.up zzz)"
  local actual
  actual="$(cat "$OUT")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "content is filtered, sorted, and deduplicated"
  else
    assert_fail "content mismatch" "got:\n$actual"
  fi

  if grep -qE '^[0-9A-F]{32}' "$OUT"; then
    assert_fail "hex placeholder filter" "a 32-char hex ID survived"
  else
    assert_pass "private-bundle hex placeholders are filtered out"
  fi

  # `square.and.arrow.up` came from both bundles; uniqueness must collapse it.
  local count
  count="$(grep -c 'square.and.arrow.up' "$OUT")"
  if [ "$count" = "1" ]; then
    assert_pass "cross-bundle duplicates collapse to one entry"
  else
    assert_fail "uniqueness" "expected 1 occurrence, got $count"
  fi
}

test_valid_file_shape() {
  section 2 "valid file shape"

  if [ -s "$OUT" ] && [ "$(tail -c 1 "$OUT")" = "" ]; then
    # tail -c 1 of a newline-terminated file is the newline, which command
    # substitution strips to empty.
    assert_pass "file is non-empty and ends with a newline"
  else
    assert_fail "trailing newline" "expected a trailing newline"
  fi
}

test_idempotent() {
  section 3 "idempotent"

  rm -f "$OUT"
  _run_generator
  local first second first_mtime second_mtime
  first="$(cat "$OUT")"
  first_mtime="$(stat -f %m "$OUT" 2>/dev/null || stat -c %Y "$OUT")"

  sleep 1
  _run_generator
  second="$(cat "$OUT")"
  second_mtime="$(stat -f %m "$OUT" 2>/dev/null || stat -c %Y "$OUT")"

  if [ "$first" = "$second" ]; then
    assert_pass "rerun produces identical content"
  else
    assert_fail "idempotency" "content changed between runs"
  fi
  if [ "$first_mtime" = "$second_mtime" ]; then
    assert_pass "unchanged content leaves the file untouched"
  else
    assert_fail "no-op write" "mtime changed on an identical rerun"
  fi
}

test_generator_contract() {
  section 4 "generator contract"

  if grep -q -- '-extract symbols raw' "$GENERATOR"; then
    assert_pass "generator extracts the symbols dictionary directly"
  else
    assert_fail "extract recipe" "expected 'plutil -extract symbols raw'"
  fi

  # The old recipe is named in the generator's header comment; strip comments
  # so only real invocations are inspected.
  if grep -vE '^[[:space:]]*#' "$GENERATOR" | grep -q -- 'plutil -p'; then
    assert_fail "no version noise" "the 'plutil -p' recipe leaks release metadata"
  else
    assert_pass "does not use the leaky 'plutil -p' recipe"
  fi

  local _arg
  for _arg in _plutil_bin _grep_bin _sort_bin _cmp_bin; do
    if grep -qE "_${_arg#_}=\"\\\$[0-9]+\"" "$GENERATOR"; then
      assert_pass "declares $_arg as a positional tool arg"
    else
      assert_fail "tool arg $_arg" "expected _${_arg#_}=\"\$N\" in the generator"
    fi
  done
}

test_skill_points_at_generated_path() {
  section 5 "skill repointed to the generated file"

  if grep -q 'Library/Application Support/nucleus/state/sf-symbols.txt' "$SKILL_MD"; then
    assert_pass "skill references the generated USER-root path"
  else
    assert_fail "skill path" "expected the generated path in SKILL.md"
  fi

  if grep -q 'macos-generate-sf-symbols' "$SKILL_MD"; then
    assert_pass "skill documents the activation step that generates the list"
  else
    assert_fail "skill provenance" "expected the activation step named in SKILL.md"
  fi

  if grep -q '.agents/skills/sf-symbols/symbols.txt' "$SKILL_MD"; then
    assert_fail "stale reference" "SKILL.md still points at the committed list"
  else
    assert_pass "skill no longer points at the committed list"
  fi

  if grep -q 'NixOS and Windows: not applicable' "$SKILL_MD"; then
    assert_pass "skill records NixOS/Windows as not applicable"
  else
    assert_fail "cross-host status" "expected an explicit N/A for NixOS/Windows"
  fi
}

test_committed_list_removed() {
  section 6 "committed list removed"

  if [ -e "$COMMITTED_LIST" ]; then
    assert_fail "committed symbols.txt" "still present in the working tree"
  else
    assert_pass "committed symbols.txt is gone"
  fi
}

test_activation_wiring() {
  section 7 "activation wiring"

  if grep -q 'macos-generate-sf-symbols = lib.hm.dag.entryAfter' "$MODULE_NIX"; then
    assert_pass "macOS module declares the activation entry"
  else
    assert_fail "activation entry" "expected macos-generate-sf-symbols in the module"
  fi

  if grep -q 'macos-generate-sf-symbols.sh' "$MODULE_NIX"; then
    assert_pass "activation entry invokes the generator script"
  else
    assert_fail "activation script" "expected the generator script path in the module"
  fi
}

test_real_framework_extraction() {
  section 8 "real framework extraction"

  if [ "$(uname -s)" != "Darwin" ] || [ ! -x /usr/bin/plutil ]; then
    # The generator is macOS-only; on other hosts this case asserts the
    # host-correct expectation (no framework, so no list to extract).
    assert_pass "real framework extraction is macOS-only"
    return
  fi

  rm -f "$OUT"
  "$GENERATOR" /usr/bin/plutil "$GREP_BIN" "$SORT_BIN" "$CMP_BIN"

  local count
  count="$(wc -l <"$OUT" | tr -d ' ')"
  if [ "$count" -gt 10000 ]; then
    assert_pass "real run extracted $count names"
  else
    assert_fail "real run count" "expected > 10000 names, got $count"
  fi

  if grep -qE '^[0-9A-F]{32}' "$OUT"; then
    assert_fail "real run filter" "a 32-char hex ID survived"
  else
    assert_pass "real run carries no hex placeholders"
  fi

  if [ "$("$SORT_BIN" -u "$OUT" | "$CMP_BIN" -s - "$OUT" && echo unique)" = "unique" ]; then
    assert_pass "real output is already sorted and unique"
  else
    assert_fail "real output shape" "output was not sorted/unique"
  fi
}

test_output_is_names_only
test_valid_file_shape
test_idempotent
test_generator_contract
test_skill_points_at_generated_path
test_committed_list_removed
test_activation_wiring
test_real_framework_extraction

finish_tests
