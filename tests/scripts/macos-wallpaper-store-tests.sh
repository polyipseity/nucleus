#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
# Tests for src/scripts/configs/converge-macos-wallpaper-store.py
#
# Verifies the WallpaperKit store convergence that keeps the macOS lock-screen
# wallpaper (the Idle surface) and every Space and display on the same folder
# choice as the desktop:
#   • every Desktop and Idle surface ends up on the wallpaper folder URL
#   • AllSpacesAndDisplays keeps its Idle surface and gains no Desktop surface
#   • unmanaged keys and non-surface state survive the rewrite
#   • a converged store is left byte-identical (idempotent)
#   • the previous store is backed up once and never overwritten
#   • a store without an image folder choice fails loudly
#   • a missing store and a bad argument list fail loudly
#   • a store macOS refuses to let us write reports its own exit status
#
# Run with: bash tests/scripts/macos-wallpaper-store-tests.sh

. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONVERGE_SCRIPT="$REPO_ROOT/src/scripts/configs/converge-macos-wallpaper-store.py"

require_command python3 "python3 is required to exercise the wallpaper store convergence"

PYTHON3=python3

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FOLDER="$TMPDIR_TEST/Pictures/wallpapers"
mkdir -p "$FOLDER"
FOLDER_URI="file://$FOLDER"
STALE_URI="$FOLDER_URI/(2026-04-07)%20sweet%20mushroom.png"

# write_fixture <path> <mode> -- build a store plist.
#   normal:   folder choice plus stale file choices and default Idle surfaces
#   no-folder: image file choices only, no folder choice to copy
write_fixture() {
  "$PYTHON3" - "$1" "$2" "$FOLDER_URI" "$STALE_URI" <<'PY'
import datetime
import plistlib
import sys

path, mode, folder_uri, stale_uri = sys.argv[1:5]
now = datetime.datetime(2026, 5, 4, 8, 14, 23)

def choice(kind, url):
    return {
        "Configuration": plistlib.dumps(
            {"type": kind, "url": {"relative": url}}, fmt=plistlib.FMT_BINARY
        ),
        "Files": [],
        "Provider": "com.apple.wallpaper.choice.image",
    }

def surface(choices):
    return {
        "Content": {
            "Choices": choices,
            "EncodedOptionValues": plistlib.dumps(
                {"values": {"color": {"_0": {}}, "placement": {"_0": {}}, "shuffleFrequency": {"_0": {}}}},
                fmt=plistlib.FMT_BINARY,
            ),
            "Shuffle": "$null",
        },
        "LastSet": now,
        "LastUse": now,
    }

def idle_surface():
    return {
        "Content": {"Choices": [{"Configuration": b"", "Files": [], "Provider": "default"}], "EncodedOptionValues": "", "Shuffle": "$null"},
        "LastSet": now,
        "LastUse": now,
    }

def desktop_surface(kind, url):
    return surface([choice(kind, url)])

folder_url = f"{folder_uri}/." if mode == "normal" else stale_uri
folder_kind = "imageFolder" if mode == "normal" else "imageFile"

store = {
    "AllSpacesAndDisplays": {"Idle": idle_surface(), "Type": "individual"},
    "Displays": {"11111111-1111-1111-1111-111111111111": {"Desktop": desktop_surface(folder_kind, folder_url), "Idle": idle_surface(), "Type": "individual"}},
    "Spaces": {
        "22222222-2222-2222-2222-222222222222": {
            "Default": {"Desktop": desktop_surface("imageFile", stale_uri), "Idle": idle_surface(), "LastUse": now, "X-Custom-Surface": "keep-me"},
            "Displays": {"33333333-3333-3333-3333-333333333333": {"Desktop": desktop_surface("imageFile", stale_uri), "Idle": idle_surface()}},
            "Type": "individual",
        }
    },
    "SystemDefault": {"Desktop": desktop_surface(folder_kind, folder_url), "Idle": idle_surface(), "Type": "individual"},
    "X-Custom-Root": "keep-me",
}

with open(path, "wb") as handle:
    plistlib.dump(store, handle, fmt=plistlib.FMT_BINARY)
PY
}

# store_urls <path> -- one "<surface-key> <url-or-shape>" line per Desktop/Idle slot.
store_urls() {
  "$PYTHON3" - "$1" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    store = plistlib.load(handle)

rows = []

def walk(node, path):
    if not isinstance(node, dict):
        return
    if "Desktop" in node or "Idle" in node:
        for key in ("Desktop", "Idle"):
            surface = node.get(key)
            if surface is None:
                rows.append(f"{key}:absent")
                continue
            choices = (surface.get("Content") or {}).get("Choices") or []
            if not choices:
                rows.append(f"{key}:nochoice")
                continue
            config = plistlib.loads(choices[0]["Configuration"])
            rows.append(f"{key}:{choices[0].get('Provider')}:{config.get('type')}:{config.get('url', {}).get('relative')}")
        return
    for key in sorted(node):
        walk(node[key], f"{path}.{key}")

walk(store, "")
print("\n".join(rows))
PY
}

# store_value <path> <python-expression> -- evaluate an expression over the store.
store_value() {
  "$PYTHON3" -c "import plistlib, sys; store = plistlib.load(open(sys.argv[1], 'rb')); print($2)" "$1"
}

# ── Test: every surface converges onto the wallpaper folder ──────────
test_converges_every_surface() {
  local store="$TMPDIR_TEST/converge.plist"
  write_fixture "$store" normal

  if ! "$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" >"$TMPDIR_TEST/converge.log" 2>&1; then
    assert_fail "converge: script exits 0" "$(cat "$TMPDIR_TEST/converge.log")"
    return
  fi

  local rows offenders
  rows="$(store_urls "$store")"
  offenders="$(printf '%s\n' "$rows" | grep -v -e ':com.apple.wallpaper.choice.image:imageFolder:' -e '^Desktop:absent$' || true)" # check-suppress:suppression_doc: grep exits 1 when no offender remains, which is the expected outcome
  if [ -z "$offenders" ]; then
    assert_pass "converge: every Desktop and Idle surface shows the wallpaper folder"
  else
    assert_fail "converge: every Desktop and Idle surface shows the wallpaper folder" "offenders: $offenders"
  fi

  if ! printf '%s\n' "$rows" | grep -q "^Idle:com.apple.wallpaper.choice.image:imageFolder:$FOLDER_URI/\.$"; then
    assert_fail "converge: AllSpacesAndDisplays Idle points at the folder" "rows: $rows"
  elif [ "$(printf '%s\n' "$rows" | grep -c "^Idle:")" -ne 5 ]; then
    assert_fail "converge: every surface keeps an Idle surface" "$(printf '%s\n' "$rows" | grep -c "^Idle:") Idle rows"
  else
    assert_pass "converge: lock-screen Idle surface follows the folder on every Space and display"
  fi

  if [ "$(store_value "$store" "'Desktop' in store['AllSpacesAndDisplays']")" = "False" ]; then
    assert_pass "converge: AllSpacesAndDisplays keeps its Idle-only shape"
  else
    assert_fail "converge: AllSpacesAndDisplays keeps its Idle-only shape" "gained a Desktop surface"
  fi
}

# ── Test: unmanaged state survives ──────────────────────────────────
test_preserves_unmanaged_state() {
  local store="$TMPDIR_TEST/preserve.plist"
  write_fixture "$store" normal
  "$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" >/dev/null 2>&1

  local root_custom surface_custom type_value content_custom
  root_custom="$(store_value "$store" "store['X-Custom-Root']")"
  surface_custom="$(store_value "$store" "store['Spaces']['22222222-2222-2222-2222-222222222222']['Default']['X-Custom-Surface']")"
  type_value="$(store_value "$store" "store['Spaces']['22222222-2222-2222-2222-222222222222']['Type']")"
  content_custom="$(store_value "$store" "'Shuffle' in store['SystemDefault']['Desktop']['Content']")"
  if [ "$root_custom" = "keep-me" ] && [ "$surface_custom" = "keep-me" ] && [ "$type_value" = "individual" ] && [ "$content_custom" = "True" ]; then
    assert_pass "converge: unmanaged keys and surface shapes survive the rewrite"
  else
    assert_fail "converge: unmanaged keys and surface shapes survive the rewrite" "root=$root_custom surface=$surface_custom type=$type_value content=$content_custom"
  fi

  local last_use
  last_use="$(store_value "$store" "store['Spaces']['22222222-2222-2222-2222-222222222222']['Default']['LastUse']")"
  if [ "$last_use" = "2026-05-04 08:14:23" ]; then
    assert_pass "converge: a surface keeps its LastUse history"
  else
    assert_fail "converge: a surface keeps its LastUse history" "got $last_use"
  fi
}

# ── Test: idempotence ───────────────────────────────────────────────
test_idempotent() {
  local store="$TMPDIR_TEST/idempotent.plist" first second out
  write_fixture "$store" normal
  "$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" >/dev/null 2>&1
  first="$(shasum -a 256 "$store" | awk '{print $1}')"
  out="$("$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" 2>&1)"
  second="$(shasum -a 256 "$store" | awk '{print $1}')"

  if [ "$first" = "$second" ] && printf '%s' "$out" | grep -q "already synced"; then
    assert_pass "converge: a converged store is left untouched"
  else
    assert_fail "converge: a converged store is left untouched" "first=$first second=$second out=$out"
  fi
}

# ── Test: backup once, then convergence again ───────────────────────
test_backup_once() {
  local store="$TMPDIR_TEST/backup.plist" backup="$TMPDIR_TEST/backup.plist.nucleus.bak"
  write_fixture "$store" normal
  "$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" >/dev/null 2>&1

  if [ ! -f "$backup" ]; then
    assert_fail "converge: the previous store is backed up" "no backup at $backup"
    return
  fi
  local original_backup_hash
  original_backup_hash="$(shasum -a 256 "$backup" | awk '{print $1}')"

  # Drift one surface back to an old picture, then converge again.
  "$PYTHON3" - "$store" "$STALE_URI" <<'PY'
import plistlib
import sys

path, stale = sys.argv[1:3]
with open(path, "rb") as handle:
    store = plistlib.load(handle)
surface = store["SystemDefault"]["Desktop"]
surface["Content"]["Choices"][0]["Configuration"] = plistlib.dumps(
    {"type": "imageFile", "url": {"relative": stale}}, fmt=plistlib.FMT_BINARY
)
with open(path, "wb") as handle:
    plistlib.dump(store, handle, fmt=plistlib.FMT_BINARY)
PY
  "$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" >/dev/null 2>&1

  if [ "$(shasum -a 256 "$backup" | awk '{print $1}')" = "$original_backup_hash" ]; then
    assert_pass "converge: the backup is written once and never overwritten"
  else
    assert_fail "converge: the backup is written once and never overwritten" "backup content changed"
  fi

  if store_urls "$store" | grep -q "$STALE_URI"; then
    assert_fail "converge: a drifted surface converges again" "stale picture still referenced"
  else
    assert_pass "converge: a drifted surface converges again"
  fi
}

# ── Test: failure modes ─────────────────────────────────────────────
test_fails_without_folder_choice() {
  local store="$TMPDIR_TEST/no-folder.plist" out rc=0
  write_fixture "$store" no-folder
  out="$("$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no image folder choice"; then
    assert_pass "converge: a store without a folder choice fails loudly"
  else
    assert_fail "converge: a store without a folder choice fails loudly" "rc=$rc out=$out"
  fi
}

test_fails_when_store_missing() {
  local out rc=0
  out="$("$PYTHON3" "$CONVERGE_SCRIPT" "$TMPDIR_TEST/absent.plist" "$FOLDER" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "wallpaper store not found"; then
    assert_pass "converge: a missing store fails loudly"
  else
    assert_fail "converge: a missing store fails loudly" "rc=$rc out=$out"
  fi
}

test_usage_requires_two_arguments() {
  local out rc=0
  out="$("$PYTHON3" "$CONVERGE_SCRIPT" "$TMPDIR_TEST/whatever.plist" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "usage:"; then
    assert_pass "converge: a bad argument list fails loudly"
  else
    assert_fail "converge: a bad argument list fails loudly" "rc=$rc out=$out"
  fi
}

test_refuses_when_store_is_read_only() {
  local dir="$TMPDIR_TEST/read-only" store="$TMPDIR_TEST/read-only/Index.plist" out rc=0
  mkdir -p "$dir"
  write_fixture "$store" normal
  chmod 555 "$dir"
  out="$("$PYTHON3" "$CONVERGE_SCRIPT" "$store" "$FOLDER" 2>&1)" || rc=$?
  chmod 755 "$dir"
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "refused write access"; then
    assert_pass "converge: a refused write reports its own exit status"
  else
    assert_fail "converge: a refused write reports its own exit status" "rc=$rc out=$out"
  fi
}

test_converges_every_surface
test_preserves_unmanaged_state
test_idempotent
test_backup_once
test_fails_without_folder_choice
test_fails_when_store_missing
test_usage_requires_two_arguments
test_refuses_when_store_is_read_only

finish_tests
