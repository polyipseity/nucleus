#!/usr/bin/env bash
# Shell tests asserting activation scripts hard-error on convergence failure.
# Activation scripts must abort (non-zero exit) when a required convergence op
# fails — no silent error, no warning replacing an error.
#
# Run with: bash tests/scripts/activation-hard-error-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
MENU_BAR_SH="$REPO_ROOT/src/scripts/menu-bar.sh"
AUTOSTART_SH="$REPO_ROOT/src/scripts/autostart.sh"
readonly MENU_BAR_SH AUTOSTART_SH

# Run a script and capture its exit code without tripping set -e.
run_capture_rc() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

test_menu_bar_activation_script_die() {
  local tmp rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/src/modules" "$tmp/src/scripts/lib"
  printf '{ } # marker\n' >"$tmp/src/flake.nix"
  cat >"$tmp/src/modules/apps.json" <<'APPSJSON'
{
  "$schema": "src/modules/apps.schema.json",
  "TestApp": {
    "displayName": "Test App",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "menuBarIcon": {
          "kind": "activation-script",
          "script": "src/scripts/lib/failing-tray.sh",
          "iconVisible": false
        }
      }
    }
  }
}
APPSJSON
  printf '#!/usr/bin/env bash\necho "failing tray script" >&2\nexit 3\n' >"$tmp/src/scripts/lib/failing-tray.sh"
  chmod +x "$tmp/src/scripts/lib/failing-tray.sh"

  rc="$(NUCLEUS_REPO_ROOT="$tmp" run_capture_rc bash "$MENU_BAR_SH" hide TestApp)"
  if [ "$rc" -ne 0 ]; then
    assert_pass "menu-bar.sh hard-errors when activation-script fails"
  else
    assert_fail "menu-bar.sh hard-errors when activation-script fails" "exit 0 despite failing sub-script"
  fi
  rm -rf "$tmp"
}

test_menu_bar_unknown_app_nonzero() {
  local tmp rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/src/modules"
  printf '{ } # marker\n' >"$tmp/src/flake.nix"
  cat >"$tmp/src/modules/apps.json" <<'APPSJSON'
{
  "$schema": "src/modules/apps.schema.json",
  "TestApp": {
    "displayName": "Test App",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "menuBarIcon": { "kind": "manual", "iconVisible": false }
      }
    }
  }
}
APPSJSON

  rc="$(NUCLEUS_REPO_ROOT="$tmp" run_capture_rc bash "$MENU_BAR_SH" hide NoSuchApp)"
  if [ "$rc" -ne 0 ]; then
    assert_pass "menu-bar.sh non-zero exit for unknown app"
  else
    assert_fail "menu-bar.sh non-zero exit for unknown app" "exit 0 for unresolved app"
  fi
  rm -rf "$tmp"
}

test_autostart_xdg_desktop_die() {
  local tmp ro rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/src/modules"
  printf '{ } # marker\n' >"$tmp/src/flake.nix"
  cat >"$tmp/src/modules/apps.json" <<'APPSJSON'
{
  "$schema": "src/modules/apps.schema.json",
  "TestApp": {
    "displayName": "Test App",
    "hosts": {
      "NixOS": {
        "platform": "NixOS",
        "autostartEnabled": true,
        "autostartDisableNative": true,
        "kind": "xdg-desktop",
        "path": "/run/current-system/sw/bin/testapp",
        "menuBarIcon": { "kind": "manual", "iconVisible": false }
      }
    }
  }
}
APPSJSON
  ro="$(mktemp -d)"
  chmod 555 "$ro"

  rc="$(NUCLEUS_REPO_ROOT="$tmp" NUCLEUS_HOST=NixOS XDG_CONFIG_HOME="$ro" run_capture_rc bash "$AUTOSTART_SH" enable TestApp)"
  chmod 755 "$ro"
  if [ "$rc" -ne 0 ]; then
    assert_pass "autostart.sh hard-errors when .desktop write fails"
  else
    assert_fail "autostart.sh hard-errors when .desktop write fails" "exit 0 despite write failure"
  fi
  rm -rf "$tmp" "$ro"
}

main() {
  test_menu_bar_activation_script_die
  test_menu_bar_unknown_app_nonzero
  test_autostart_xdg_desktop_die

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
