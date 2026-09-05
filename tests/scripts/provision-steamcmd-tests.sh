#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
# Tests for src/scripts/configs/provision-steamcmd.py
#
# Verifies the Python helper correctly:
#   • Extracts steamcmd_install_path from a RimSort settings JSON
#   • Returns empty string when steamcmd_install_path is missing
#   • Returns empty string when instances.Default is missing
#   • Returns empty string when the JSON has no instances key
#
# Run with: bash tests/scripts/provision-steamcmd-tests.sh

. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION_PY="$REPO_ROOT/src/scripts/configs/provision-steamcmd.py"

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

# Helper: run provision-steamcmd.py with a settings JSON file and capture output.
run_provision() {
  local settings_path="$1"
  "$PYTHON3" "$PROVISION_PY" "$settings_path"
}

# ── Test: extracts steamcmd_install_path from valid JSON ──────────────
test_extracts_steamcmd_path() {
  local settings="$TMPDIR_TEST/valid.json"
  cat >"$settings" <<'EOF'
{
  "current_instance": "Default",
  "instances": {
    "Default": {
      "steamcmd_install_path": "~/.local/share/RimSort/instances/Default",
      "game_folder": "/path/to/game"
    }
  }
}
EOF
  local result
  result=$(run_provision "$settings")
  # The Python script returns the raw value with literal tilde (not expanded).
  local _t='~'
  local expected="${_t}/.local/share/RimSort/instances/Default"
  if [ "$result" = "$expected" ]; then
    assert_pass "extracts_steamcmd_path: path extracted correctly"
  else
    assert_fail "extracts_steamcmd_path: path extracted correctly" "expected '$expected', got '$result'"
  fi
}

# ── Test: returns empty when steamcmd_install_path is missing ─────────
test_missing_steamcmd_path() {
  local settings="$TMPDIR_TEST/no_path.json"
  cat >"$settings" <<'EOF'
{
  "current_instance": "Default",
  "instances": {
    "Default": {
      "game_folder": "/path/to/game",
      "steam_client_integration": true
    }
  }
}
EOF
  local result
  result=$(run_provision "$settings")
  if [ -z "$result" ]; then
    assert_pass "missing_steamcmd_path: returns empty"
  else
    assert_fail "missing_steamcmd_path: returns empty" "expected empty, got '$result'"
  fi
}

# ── Test: returns empty when instances.Default is missing ─────────────
test_missing_default_instance() {
  local settings="$TMPDIR_TEST/no_default.json"
  cat >"$settings" <<'EOF'
{
  "current_instance": "Default",
  "instances": {}
}
EOF
  local result
  result=$(run_provision "$settings")
  if [ -z "$result" ]; then
    assert_pass "missing_default_instance: returns empty"
  else
    assert_fail "missing_default_instance: returns empty" "expected empty, got '$result'"
  fi
}

# ── Test: returns empty when instances key is missing ─────────────────
test_missing_instances_key() {
  local settings="$TMPDIR_TEST/no_instances.json"
  cat >"$settings" <<'EOF'
{
  "current_instance": "Default"
}
EOF
  local result
  result=$(run_provision "$settings")
  if [ -z "$result" ]; then
    assert_pass "missing_instances_key: returns empty"
  else
    assert_fail "missing_instances_key: returns empty" "expected empty, got '$result'"
  fi
}

# ── Test: extracts Windows-style path ─────────────────────────────────
test_windows_style_path() {
  local settings="$TMPDIR_TEST/windows.json"
  cat >"$settings" <<'EOF'
{
  "instances": {
    "Default": {
      "steamcmd_install_path": "~/AppData/Local/RimSort/instances/Default",
      "game_folder": "C:/Program Files (x86)/Steam/steamapps/common/RimWorld"
    }
  }
}
EOF
  local result
  result=$(run_provision "$settings")
  # The Python script returns the raw value with literal tilde (not expanded).
  local _t='~'
  local expected="${_t}/AppData/Local/RimSort/instances/Default"
  if [ "$result" = "$expected" ]; then
    assert_pass "windows_style_path: path extracted correctly"
  else
    assert_fail "windows_style_path: path extracted correctly" "expected '$expected', got '$result'"
  fi
}

# ── Test: absolute path preserved as-is ───────────────────────────────
test_absolute_path() {
  local settings="$TMPDIR_TEST/absolute.json"
  cat >"$settings" <<'EOF'
{
  "instances": {
    "Default": {
      "steamcmd_install_path": "/opt/rimsort/steamcmd"
    }
  }
}
EOF
  local result
  result=$(run_provision "$settings")
  if [ "$result" = "/opt/rimsort/steamcmd" ]; then
    assert_pass "absolute_path: path preserved as-is"
  else
    assert_fail "absolute_path: path preserved as-is" "expected '/opt/rimsort/steamcmd', got '$result'"
  fi
}

# ── Run all tests ───────────────────────────────────────────────────
test_extracts_steamcmd_path
test_missing_steamcmd_path
test_missing_default_instance
test_missing_instances_key
test_windows_style_path
test_absolute_path

if [ "$TESTS_FAILED" -gt 0 ]; then
  printf '%d failed, %d passed\n' "$TESTS_FAILED" "$TESTS_PASSED"
  exit 1
fi

printf 'all %d tests passed.\n' "$TESTS_PASSED"
exit 0
