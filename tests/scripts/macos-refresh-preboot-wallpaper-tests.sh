#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
# Tests for src/hosts/MacBook/scripts/macos-refresh-preboot-wallpaper.sh
#
# Uses PREFLIGHT_* overrides to operate on temp dirs (no real Preboot writes).
# Verifies: renders 1280x832 PNG into Preboot dir, idempotent via state file.

. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/src/hosts/MacBook/scripts/macos-refresh-preboot-wallpaper.sh"

require_command python3 "python3 is required"
if [ "$(uname -s)" != "Darwin" ]; then
  skip "macos-refresh-preboot-wallpaper: only meaningful on macOS"
fi

require_command sips "sips is required on macOS"
require_command shasum "shasum is required"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Setup temp layout
WALLPAPERS_DIR="$TMPDIR_TEST/wallpapers"
mkdir -p "$WALLPAPERS_DIR"

# Deterministic source fixture: generate a small PNG (no host-specific assets).
python3 - "$WALLPAPERS_DIR/test-wallpaper.png" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
w = h = 64
raw = b"".join(b"\x00" + bytes((i % 256, (i * 2) % 256, (i * 3) % 256)) * w for i in range(h))
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
with open(path, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n")
    f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
    f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
    f.write(chunk(b"IEND", b""))
PY

PREBOOT_ROOT="$TMPDIR_TEST/Preboot"
GUID="TEST-GUID-1234"
mkdir -p "$PREBOOT_ROOT/vol1/var/db/Wallpapers/$GUID"
STATE_DIR="$TMPDIR_TEST/state"
mkdir -p "$STATE_DIR"

export PREFLIGHT_USER="testuser"
export PREFLIGHT_HOME="$TMPDIR_TEST/home"
export PREFLIGHT_WALLPAPERS_DIR="$WALLPAPERS_DIR"
export PREFLIGHT_PREBOOT_ROOT="$PREBOOT_ROOT"
export PREFLIGHT_STATE_DIR="$STATE_DIR"
export PREFLIGHT_TARGET_GUID="$GUID"
mkdir -p "$TMPDIR_TEST/home/Pictures/wallpapers"

if ! bash "$SCRIPT_UNDER_TEST" >"$TMPDIR_TEST/run1.log" 2>&1; then
  assert_fail "preboot wallpaper script: first run succeeds" "$(cat "$TMPDIR_TEST/run1.log")"
else
  assert_pass "preboot wallpaper script: first run succeeds"
fi

TARGET_PNG="$PREBOOT_ROOT/vol1/var/db/Wallpapers/$GUID/Wallpaper.png"
if [ -f "$TARGET_PNG" ]; then
  assert_pass "preboot wallpaper script: Wallpaper.png created"
else
  assert_fail "preboot wallpaper script: Wallpaper.png created" "missing $TARGET_PNG"
fi

if [ -f "$TARGET_PNG" ]; then
  W=$(sips -g pixelWidth "$TARGET_PNG" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  H=$(sips -g pixelHeight "$TARGET_PNG" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  if [ "$W" = "1280" ] && [ "$H" = "832" ]; then
    assert_pass "preboot wallpaper script: output is 1280x832"
  else
    assert_fail "preboot wallpaper script: output is 1280x832" "got ${W}x${H}"
  fi
fi

if ! bash "$SCRIPT_UNDER_TEST" >"$TMPDIR_TEST/run2.log" 2>&1; then
  assert_fail "preboot wallpaper script: second run succeeds" "$(cat "$TMPDIR_TEST/run2.log")"
else
  assert_pass "preboot wallpaper script: second run succeeds"
fi
if grep -q "already up to date" "$TMPDIR_TEST/run2.log"; then
  assert_pass "preboot wallpaper script: second run is idempotent"
else
  assert_fail "preboot wallpaper script: second run is idempotent" "$(cat "$TMPDIR_TEST/run2.log")"
fi

finish_tests
