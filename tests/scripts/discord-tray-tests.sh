#!/usr/bin/env bash
# Shell tests for src/scripts/lib/discord-tray.sh: system-tray visibility
# convergence for stable Discord and Discord Canary, plus idempotency.
#
# Run with: bash tests/scripts/discord-tray-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=./user-registry-fixture.sh
. "$SCRIPT_DIR/user-registry-fixture.sh"

DISCORD_TRAY="$REAL_REPO_ROOT/src/scripts/lib/discord-tray.sh"
readonly DISCORD_TRAY

# Run discord-tray.sh with an isolated HOME so it never touches real config.
run_discord_tray() {
  local test_home="$1" visible="$2" app_key="${3:-}"
  local args=("$visible")
  [ -n "$app_key" ] && args+=("$app_key")
  HOME="$test_home" "$DISCORD_TRAY" "${args[@]}"
}

# Read the literal boolean value of .systemTray (jq -r '.x // empty' would
# collapse a real false into empty, so read the raw token instead).
read_system_tray() {
  local config_path="$1"
  jq -r 'if .systemTray == true then "true" elif .systemTray == false then "false" else "absent" end' "$config_path"
}

assert_system_tray() {
  local test_name="$1" config_path="$2" expected="$3"
  if [ ! -f "$config_path" ]; then
    assert_fail "$test_name" "missing config at $config_path"
    return 1
  fi
  local actual
  actual="$(read_system_tray "$config_path")"
  if [ "$actual" != "$expected" ]; then
    assert_fail "$test_name" "systemTray=$actual, want $expected"
    return 1
  fi
  assert_pass "$test_name"
}

test_stable_hides_tray() {
  local home
  home="$(mktemp -d)"
  trap 'rm -rf "${home:-}"' RETURN

  run_discord_tray "$home" "false" "Discord"
  assert_system_tray "stable: systemTray=false after hide" \
    "$home/.config/discord/settings.json" "false"

  # Idempotent: re-running with the same arg must not error or change value.
  run_discord_tray "$home" "false" "Discord"
  assert_system_tray "stable: idempotent hide" \
    "$home/.config/discord/settings.json" "false"
}

test_canary_routes_to_canary_config() {
  local home
  home="$(mktemp -d)"
  trap 'rm -rf "${home:-}"' RETURN

  run_discord_tray "$home" "false" "Discord Canary"
  assert_system_tray "canary: routes to discordcanary config" \
    "$home/.config/discordcanary/settings.json" "false"

  # Stable config must remain untouched when only canary is targeted.
  if [ -e "$home/.config/discord/settings.json" ]; then
    assert_fail "canary: stable config untouched" "stable config was created"
    return 1
  fi
  assert_pass "canary: stable config untouched"
}

test_default_app_key_is_stable() {
  local home
  home="$(mktemp -d)"
  trap 'rm -rf "${home:-}"' RETURN

  # No app key -> defaults to stable Discord.
  run_discord_tray "$home" "false"
  assert_system_tray "default app key: stable config" \
    "$home/.config/discord/settings.json" "false"
}

main() {
  test_stable_hides_tray
  test_canary_routes_to_canary_config
  test_default_app_key_is_stable

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
