#!/usr/bin/env bash
# Shell tests for src/scripts/configs/symlink-cursor-config.sh: IDE settings
# symlink (Class C) and overlay skip from ~/.cursor convergence (Class B).
#
# Run with: bash tests/scripts/symlink-cursor-config-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"
# shellcheck source=./user-registry-fixture.sh
. "$SCRIPT_DIR/user-registry-fixture.sh"

SYMLINK_CURSOR_CONFIG="$REAL_REPO_ROOT/src/scripts/configs/symlink-cursor-config.sh"
readonly SYMLINK_CURSOR_CONFIG

test_ide_settings_symlink_and_overlay_skip() {
  local ide_user_dir expected_ide_settings
  _scc_test_home="$(mktemp -d)"
  cleanup() {
    [ -d "$_scc_test_home" ] || return 0
    if [ "$(uname -s)" = "Darwin" ]; then
      find "$_scc_test_home" -type l -exec /usr/bin/chflags -h nouchg {} +
    fi
    rm -rf "$_scc_test_home"
  }
  trap cleanup RETURN
  mkdir -p "$_scc_test_home/.agents"
  case "$(uname -s)" in
  Darwin)
    ide_user_dir="$_scc_test_home/Library/Application Support/Cursor/User"
    ;;
  Linux)
    ide_user_dir="$_scc_test_home/.config/Cursor/User"
    ;;
  *)
    assert_fail "ide settings symlink" "unsupported platform $(uname -s)"
    return 1
    ;;
  esac

  HOME="$_scc_test_home" "$SYMLINK_CURSOR_CONFIG" "$FIXTURE_REPO_ROOT" "$FIXTURE_USERNAME"

  expected_ide_settings="$FIXTURE_REPO_ROOT/src/users/default/cursor/settings.json"
  if [ ! -L "$ide_user_dir/settings.json" ]; then
    assert_fail "ide settings symlink" "missing symlink at $ide_user_dir/settings.json"
    return 1
  fi
  if [ "$(readlink "$ide_user_dir/settings.json")" != "$expected_ide_settings" ]; then
    assert_fail "ide settings symlink" "unexpected target: $(readlink "$ide_user_dir/settings.json")"
    return 1
  fi
  assert_pass "ide settings symlink"

  if [ -e "$_scc_test_home/.cursor/settings.json" ] || [ -L "$_scc_test_home/.cursor/settings.json" ]; then
    assert_fail "ide settings skipped from cursor dir" "settings.json present in ~/.cursor"
    return 1
  fi
  if [ -e "$_scc_test_home/.cursor/settings.schema.json" ] || [ -L "$_scc_test_home/.cursor/settings.schema.json" ]; then
    assert_fail "ide settings skipped from cursor dir" "settings.schema.json present in ~/.cursor"
    return 1
  fi
  assert_pass "ide settings skipped from cursor dir"

  if [ ! -L "$_scc_test_home/.cursor/mcp.json" ]; then
    assert_fail "cursor overlay still converges" "missing mcp.json symlink in ~/.cursor"
    return 1
  fi
  assert_pass "cursor overlay still converges"
}

main() {
  test_ide_settings_symlink_and_overlay_skip

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
