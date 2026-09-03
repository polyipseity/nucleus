#!/usr/bin/env bash
# Unit tests for strip-embedded-metadata.py.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

HELPER="$SCRIPT_DIR/../../src/scripts/lib/strip-embedded-metadata.py"
EXIFTOOL="$(command -v exiftool 2>/dev/null || true)"

if [[ -z "$EXIFTOOL" ]]; then
  echo "SKIP: exiftool not found in PATH (requires Nix environment)"
  exit 0
fi

# Helper: create a minimal OOXML ZIP at $1 with optional embedded media.
# $1 = output path, $2 = "with-media" or "no-media"
create_test_ooxml() {
  local out="$1" media="$2"
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Create minimal OOXML structure.
  mkdir -p "$tmpdir/word" "$tmpdir/docProps"
  echo '<?xml version="1.0"?><document/>' >"$tmpdir/word/document.xml"
  echo '<Properties/>' >"$tmpdir/docProps/core.xml"

  if [[ "$media" == "with-media" ]]; then
    mkdir -p "$tmpdir/word/media"
    # Minimal JPEG file (SOI marker + JFIF APP0 + EOI).
    printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9' \
      >"$tmpdir/word/media/image1.jpg"
    # Minimal PNG file.
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' \
      >"$tmpdir/word/media/image2.png"
  fi

  (cd "$tmpdir" && zip -qr "$out" . -x '.*')
  rm -rf "$tmpdir"
}

test_ooxml_with_media_strips_metadata() {
  local src dst rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  create_test_ooxml "$src" "with-media"
  python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  rm -f "$src" "$dst"
  if [ "$rc" -eq 0 ]; then
    assert_pass "OOXML with media: exit 0"
  else
    assert_fail "OOXML with media: exit 0" "rc=$rc"
  fi
}

test_ooxml_no_media_unchanged() {
  local src dst rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  create_test_ooxml "$src" "no-media"
  python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  rm -f "$src" "$dst"
  if [ "$rc" -eq 0 ]; then
    assert_pass "OOXML without media: exit 0 (no-op)"
  else
    assert_fail "OOXML without media: exit 0 (no-op)" "rc=$rc"
  fi
}

test_non_zip_input_exits_1() {
  local fake dst rc=0
  fake="$(mktemp)"
  echo "not a zip" >"$fake"
  dst="$(mktemp)"
  python3 "$HELPER" "$fake" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  rm -f "$fake" "$dst"
  if [ "$rc" -eq 1 ]; then
    assert_pass "Non-ZIP input: exit 1"
  else
    assert_fail "Non-ZIP input: exit 1" "rc=$rc"
  fi
}

test_empty_zip() {
  local src dst tmpdir rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  tmpdir="$(mktemp -d)"
  (cd "$tmpdir" && zip -qr "$src" . -x '.*')
  rm -rf "$tmpdir"
  python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  rm -f "$src" "$dst"
  if [ "$rc" -eq 0 ]; then
    assert_pass "Empty ZIP: exit 0"
  else
    assert_fail "Empty ZIP: exit 0" "rc=$rc"
  fi
}

test_multiple_image_formats() {
  local src dst rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  create_test_ooxml "$src" "with-media"
  local out
  out="$(python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "2 files processed"; then
    assert_pass "Multiple formats: 2 files processed"
  else
    assert_fail "Multiple formats: 2 files processed" "rc=$rc out=$out"
  fi
  rm -f "$src" "$dst"
}

test_output_file_is_valid_zip() {
  local src dst rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  create_test_ooxml "$src" "with-media"
  python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  local valid=0
  python3 -c "import zipfile; zipfile.ZipFile('$dst')" 2>/dev/null || valid=$?
  rm -f "$src" "$dst"
  if [ "$rc" -eq 0 ] && [ "$valid" -eq 0 ]; then
    assert_pass "Output is a valid ZIP"
  else
    assert_fail "Output is a valid ZIP" "rc=$rc valid=$valid"
  fi
}

test_file_order_preserved() {
  local src dst rc=0
  src="$(mktemp)"
  dst="$(mktemp)"
  create_test_ooxml "$src" "with-media"
  python3 "$HELPER" "$src" "$dst" "$EXIFTOOL" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    local src_names dst_names
    src_names="$(python3 -c "import zipfile; [print(i.filename) for i in zipfile.ZipFile('$src').infolist()]")"
    dst_names="$(python3 -c "import zipfile; [print(i.filename) for i in zipfile.ZipFile('$dst').infolist()]")"
    if [ "$src_names" = "$dst_names" ]; then
      assert_pass "File order preserved"
    else
      assert_fail "File order preserved" "Order mismatch"
    fi
  else
    assert_fail "File order preserved" "Script failed rc=$rc"
  fi
  rm -f "$src" "$dst"
}

section 1 "Strip embedded metadata tests"
echo ""
test_ooxml_with_media_strips_metadata
test_ooxml_no_media_unchanged
test_non_zip_input_exits_1
test_empty_zip
test_multiple_image_formats
test_output_file_is_valid_zip
test_file_order_preserved

echo ""
echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
