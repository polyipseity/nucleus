#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
# Tests for src/scripts/configs/merge-rimsort-json.py
#
# Verifies the Python merge script correctly:
#   • Creates a new settings.json from scratch with instances.Default nesting
#   • Merges managed keys into existing settings without clobbering unmanaged keys
#   • Preserves app-owned keys (theme, sorting, window state) in instances.Default
#   • Creates instances.Default nesting when missing
#   • Handles empty and malformed input gracefully
#
# Run with: bash tests/scripts/merge-rimsort-json-tests.sh

. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MERGE_SCRIPT="$REPO_ROOT/src/scripts/configs/merge-rimsort-json.py"

# Detect python3: prefer python3, fall back to python.
PYTHON3=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON3="$candidate"
    break
  fi
done
if [ -z "$PYTHON3" ]; then
  echo "SKIP: python3 not found" >&2
  exit 0
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Helper: run merge with managed JSON argument.
run_merge() {
  local settings_path="$1"
  local managed_json="$2"
  "$PYTHON3" "$MERGE_SCRIPT" "$settings_path" "$managed_json"
}

# Helper: read a JSON value via python.
json_get() {
  local file="$1"
  local expr="$2"
  "$PYTHON3" -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps($expr))" "$file"
}

# ── Test: create new file from scratch ──────────────────────────────
test_create_new_file() {
  local settings="$TMPDIR_TEST/create.json"
  local managed='{"instances":{"Default":{"game_folder":"/path/to/game","workshop_folder":"/path/workshop/content/294100"}}}'

  run_merge "$settings" "$managed"

  if [ ! -f "$settings" ]; then
    assert_fail "create_new_file: settings file created" "file missing"
    return
  fi

  local game_folder
  game_folder=$(json_get "$settings" "d['instances']['Default']['game_folder']")
  if [ "$game_folder" = '"/path/to/game"' ]; then
    assert_pass "create_new_file: game_folder set"
  else
    assert_fail "create_new_file: game_folder set" "expected '/path/to/game', got $game_folder"
  fi

  local workshop
  workshop=$(json_get "$settings" "d['instances']['Default']['workshop_folder']")
  if [ "$workshop" = '"/path/workshop/content/294100"' ]; then
    assert_pass "create_new_file: workshop_folder set"
  else
    assert_fail "create_new_file: workshop_folder set" "expected workshop path, got $workshop"
  fi
}

# ── Test: merge preserves unmanaged keys ────────────────────────────
test_preserves_unmanaged_keys() {
  local settings="$TMPDIR_TEST/preserve.json"
  cat >"$settings" <<'EOF'
{
    "current_instance": "Default",
    "instances": {
        "Default": {
            "game_folder": "/old/path",
            "theme": "dark",
            "sort_method": "lexicographic"
        }
    }
}
EOF
  local managed='{"instances":{"Default":{"game_folder":"/new/path","workshop_folder":"/ws/294100"}}}'

  run_merge "$settings" "$managed"

  local theme
  theme=$(json_get "$settings" "d['instances']['Default']['theme']")
  if [ "$theme" = '"dark"' ]; then
    assert_pass "preserves_unmanaged: theme preserved"
  else
    assert_fail "preserves_unmanaged: theme preserved" "expected 'dark', got $theme"
  fi

  local sort_method
  sort_method=$(json_get "$settings" "d['instances']['Default']['sort_method']")
  if [ "$sort_method" = '"lexicographic"' ]; then
    assert_pass "preserves_unmanaged: sort_method preserved"
  else
    assert_fail "preserves_unmanaged: sort_method preserved" "expected 'lexicographic', got $sort_method"
  fi

  local current_instance
  current_instance=$(json_get "$settings" "d['current_instance']")
  if [ "$current_instance" = '"Default"' ]; then
    assert_pass "preserves_unmanaged: top-level key preserved"
  else
    assert_fail "preserves_unmanaged: top-level key preserved" "expected 'Default', got $current_instance"
  fi

  local game_folder
  game_folder=$(json_get "$settings" "d['instances']['Default']['game_folder']")
  if [ "$game_folder" = '"/new/path"' ]; then
    assert_pass "preserves_unmanaged: game_folder updated"
  else
    assert_fail "preserves_unmanaged: game_folder updated" "expected '/new/path', got $game_folder"
  fi
}

# ── Test: creates instances.Default nesting when missing ────────────
test_creates_nesting() {
  local settings="$TMPDIR_TEST/nesting.json"
  cat >"$settings" <<'EOF'
{
    "current_instance": "Default"
}
EOF
  local managed='{"instances":{"Default":{"game_folder":"/game/path","steam_client_integration":true}}}'

  run_merge "$settings" "$managed"

  local game_folder
  game_folder=$(json_get "$settings" "d['instances']['Default']['game_folder']")
  if [ "$game_folder" = '"/game/path"' ]; then
    assert_pass "creates_nesting: instances.Default created with game_folder"
  else
    assert_fail "creates_nesting: instances.Default created" "expected '/game/path', got $game_folder"
  fi

  local steam_ci
  steam_ci=$(json_get "$settings" "d['instances']['Default']['steam_client_integration']")
  if [ "$steam_ci" = "true" ]; then
    assert_pass "creates_nesting: steam_client_integration set"
  else
    assert_fail "creates_nesting: steam_client_integration set" "expected true, got $steam_ci"
  fi

  local current_instance
  current_instance=$(json_get "$settings" "d['current_instance']")
  if [ "$current_instance" = '"Default"' ]; then
    assert_pass "creates_nesting: top-level keys preserved"
  else
    assert_fail "creates_nesting: top-level keys preserved" "expected 'Default', got $current_instance"
  fi
}

# ── Test: merge sets Steam integration flags ────────────────────────
test_steam_integration_flags() {
  local settings="$TMPDIR_TEST/steam.json"
  local managed='{"instances":{"Default":{"steam_client_integration":true,"launch_via_steam_protocol":true}}}'

  run_merge "$settings" "$managed"

  local steam_ci
  steam_ci=$(json_get "$settings" "d['instances']['Default']['steam_client_integration']")
  if [ "$steam_ci" = "true" ]; then
    assert_pass "steam_flags: steam_client_integration true"
  else
    assert_fail "steam_flags: steam_client_integration true" "expected true, got $steam_ci"
  fi

  local launch_steam
  launch_steam=$(json_get "$settings" "d['instances']['Default']['launch_via_steam_protocol']")
  if [ "$launch_steam" = "true" ]; then
    assert_pass "steam_flags: launch_via_steam_protocol true"
  else
    assert_fail "steam_flags: launch_via_steam_protocol true" "expected true, got $launch_steam"
  fi
}

# ── Test: empty existing file handled gracefully ────────────────────
test_empty_existing_file() {
  local settings="$TMPDIR_TEST/empty.json"
  touch "$settings"
  local managed='{"instances":{"Default":{"game_folder":"/game"}}}'

  run_merge "$settings" "$managed"

  local game_folder
  game_folder=$(json_get "$settings" "d['instances']['Default']['game_folder']")
  if [ "$game_folder" = '"/game"' ]; then
    assert_pass "empty_file: game_folder set from scratch"
  else
    assert_fail "empty_file: game_folder set from scratch" "expected '/game', got $game_folder"
  fi
}

# ── Test: steamcmd_install_path merged and preserved ───────────────
# ── Test: idempotent merge ──────────────────────────────────────────
test_idempotent_merge() {
  local settings="$TMPDIR_TEST/idempotent.json"
  local managed='{"instances":{"Default":{"game_folder":"/game","workshop_folder":"/ws/294100","steam_client_integration":true}}}'

  run_merge "$settings" "$managed"
  run_merge "$settings" "$managed"

  local game_folder
  game_folder=$(json_get "$settings" "d['instances']['Default']['game_folder']")
  if [ "$game_folder" = '"/game"' ]; then
    assert_pass "idempotent: game_folder stable after double merge"
  else
    assert_fail "idempotent: game_folder stable after double merge" "expected '/game', got $game_folder"
  fi
}

# ── Test: steamcmd_install_path merged and preserved ───────────────
test_steamcmd_install_path() {
  local settings="$TMPDIR_TEST/steamcmd.json"
  local managed='{"instances":{"Default":{"steamcmd_install_path":"~/.local/share/RimSort/instances/Default","game_folder":"/game"}}}'

  run_merge "$settings" "$managed"

  local steamcmd
  steamcmd=$(json_get "$settings" "d['instances']['Default']['steamcmd_install_path']")
  if [ "$steamcmd" = '"~/.local/share/RimSort/instances/Default"' ]; then
    assert_pass "steamcmd: steamcmd_install_path set"
  else
    assert_fail "steamcmd: steamcmd_install_path set" "expected default path, got $steamcmd"
  fi

  # Verify idempotent
  run_merge "$settings" "$managed"
  steamcmd=$(json_get "$settings" "d['instances']['Default']['steamcmd_install_path']")
  if [ "$steamcmd" = '"~/.local/share/RimSort/instances/Default"' ]; then
    assert_pass "steamcmd: stable after double merge"
  else
    assert_fail "steamcmd: stable after double merge" "expected default path, got $steamcmd"
  fi
}

# ── Test: current_instance top-level merged ────────────────────────
test_current_instance_top_level() {
  local settings="$TMPDIR_TEST/current_instance.json"
  local managed='{"current_instance":"Default","instances":{"Default":{"game_folder":"/game"}}}'

  run_merge "$settings" "$managed"

  local ci
  ci=$(json_get "$settings" "d['current_instance']")
  if [ "$ci" = '"Default"' ]; then
    assert_pass "current_instance: top-level key set"
  else
    assert_fail "current_instance: top-level key set" "expected 'Default', got $ci"
  fi

  # Verify idempotent
  run_merge "$settings" "$managed"
  ci=$(json_get "$settings" "d['current_instance']")
  if [ "$ci" = '"Default"' ]; then
    assert_pass "current_instance: stable after double merge"
  else
    assert_fail "current_instance: stable after double merge" "expected 'Default', got $ci"
  fi
}

# ── Run all tests ───────────────────────────────────────────────────
test_create_new_file
test_preserves_unmanaged_keys
test_creates_nesting
test_steam_integration_flags
test_empty_existing_file
test_idempotent_merge
test_steamcmd_install_path
test_current_instance_top_level

if [ "$TESTS_FAILED" -gt 0 ]; then
  printf '%d failed, %d passed\n' "$TESTS_FAILED" "$TESTS_PASSED"
  exit 1
fi

printf 'all %d tests passed.\n' "$TESTS_PASSED"
exit 0
