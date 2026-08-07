#!/usr/bin/env bash
# Shell parity tests for src/scripts/lib/resolve-user-config.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

RESOLVER="$REPO_ROOT/src/scripts/lib/resolve-user-config.sh"
# shellcheck source=/dev/null
. "$RESOLVER"

export NUCLEUS_REPO_ROOT="$REPO_ROOT"

test_default_starship_file() {
  local resolved expected
  resolved="$(resolve_user_config_file polyipseity starship starship.toml)"
  expected="$REPO_ROOT/src/users/default/starship/starship.toml"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves default starship.toml"
  else
    assert_fail "resolves default starship.toml" "got $resolved"
  fi
}

test_nested_path_uses_first_level_directory() {
  local resolved expected
  resolved="$(resolve_user_config_file polyipseity direnv lib/apple-sdk-override.sh)"
  expected="$REPO_ROOT/src/users/default/direnv/lib/apple-sdk-override.sh"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves nested path via first-level lib directory"
  else
    assert_fail "resolves nested path via first-level lib directory" "got $resolved"
  fi
}

test_list_first_level_entries_union() {
  local entries
  entries="$(list_user_config_first_level_entries polyipseity agents)"
  if echo "$entries" | grep -qx 'clawhub-skills.json' && echo "$entries" | grep -qx 'skills'; then
    assert_pass "lists merged first-level agents entries"
  else
    assert_fail "lists merged first-level agents entries" "got: $entries"
  fi
}

test_first_level_entry_resolves_directory() {
  local resolved expected
  resolved="$(resolve_user_config_first_level_entry polyipseity agents skills)"
  expected="$REPO_ROOT/src/users/default/agents/skills"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves first-level agents/skills directory"
  else
    assert_fail "resolves first-level agents/skills directory" "got $resolved"
  fi
}

test_missing_file_fails() {
  if resolve_user_config_file nobody missing-config file.txt >/dev/null 2>&1; then
    assert_fail "missing file fails fast" "expected non-zero exit"
  else
    assert_pass "missing file fails fast"
  fi
}

test_wallpaper_encrypted_blob_path() {
  local resolved expected
  resolved="$(resolve_wallpaper_encrypted_blob polyipseity "(2026-04-07) sweet mushroom.png.sops")"
  expected="$REPO_ROOT/src/users/polyipseity/wallpapers/encrypted/(2026-04-07) sweet mushroom.png.sops"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves wallpaper encrypted blob path"
  else
    assert_fail "resolves wallpaper encrypted blob path" "got $resolved"
  fi
}

test_list_wallpaper_encrypted_blobs() {
  local blobs
  blobs="$(list_wallpaper_encrypted_blobs polyipseity)"
  if echo "$blobs" | grep -qx '(2026-04-07) sweet mushroom.png.sops'; then
    assert_pass "lists wallpaper encrypted blobs"
  else
    assert_fail "lists wallpaper encrypted blobs" "got: $blobs"
  fi
}

test_default_wallpaper_unencrypted_dir() {
  local resolved expected
  resolved="$(resolve_user_config_first_level_entry polyipseity wallpapers wallpapers)"
  expected="$REPO_ROOT/src/users/default/wallpapers/wallpapers"
  if [ "$resolved" = "$expected" ]; then
    assert_pass "resolves default wallpapers/wallpapers directory"
  else
    assert_fail "resolves default wallpapers/wallpapers directory" "got $resolved"
  fi
}

test_default_starship_file
test_nested_path_uses_first_level_directory
test_list_first_level_entries_union
test_first_level_entry_resolves_directory
test_missing_file_fails
test_wallpaper_encrypted_blob_path
test_list_wallpaper_encrypted_blobs
test_default_wallpaper_unencrypted_dir
