#!/usr/bin/env bash
# Tests that app-autostart convergence removes an app-owned LaunchAgent plist in
# both plist forms, and leaves a foreign one alone.
#
# The regression this guards: parsing only the ProgramArguments array left an
# app-owned plist that declares the scalar <key>Program</key> (AltTab) registered,
# so the app started twice — once from its own agent and once from ours.
#
# Run with: bash tests/scripts/autostart-launchagent-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
AUTOSTART_SH="$REPO_ROOT/src/scripts/autostart.sh"
readonly AUTOSTART_SH

# Build a fixture repo with a two-app registry and a fixture home whose
# LaunchAgents directory holds the app-owned plists under test.
make_fixture() {
  FIXTURE_ROOT="$(mktemp -d)"
  FIXTURE_HOME="$FIXTURE_ROOT/home"
  FIXTURE_AGENTS="$FIXTURE_HOME/Library/LaunchAgents"
  mkdir -p "$FIXTURE_AGENTS" "$FIXTURE_ROOT/src/modules"
  printf '{ } # marker\n' >"$FIXTURE_ROOT/src/flake.nix"
  cat >"$FIXTURE_ROOT/src/modules/apps.json" <<'APPSJSON'
{
  "$schema": "src/modules/apps.schema.json",
  "AppOwned": {
    "displayName": "AppOwned",
    "description": "fixture app whose own plist declares a scalar Program",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "autostartEnabled": false,
        "autostartDisableNative": true,
        "kind": "login-item",
        "path": "/Applications/AppOwned.app",
        "bundleId": "com.example.appowned"
      },
      "NixOS": {
        "platform": "NixOS",
        "type": "omitted",
        "justification": "test fixture"
      },
      "Windows": {
        "platform": "Windows",
        "type": "omitted",
        "justification": "test fixture"
      }
    }
  },
  "ArrayApp": {
    "displayName": "ArrayApp",
    "description": "fixture app whose own plist declares ProgramArguments",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "autostartEnabled": false,
        "autostartDisableNative": true,
        "kind": "login-item",
        "path": "/Applications/ArrayApp.app",
        "bundleId": "com.example.arrayapp"
      },
      "NixOS": {
        "platform": "NixOS",
        "type": "omitted",
        "justification": "test fixture"
      },
      "Windows": {
        "platform": "Windows",
        "type": "omitted",
        "justification": "test fixture"
      }
    }
  },
  "ForeignApp": {
    "displayName": "ForeignApp",
    "description": "fixture app whose plist belongs to something else",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "autostartEnabled": false,
        "autostartDisableNative": true,
        "kind": "login-item",
        "path": "/Applications/ForeignApp.app",
        "bundleId": "com.example.foreignapp"
      },
      "NixOS": {
        "platform": "NixOS",
        "type": "omitted",
        "justification": "test fixture"
      },
      "Windows": {
        "platform": "Windows",
        "type": "omitted",
        "justification": "test fixture"
      }
    }
  }
}
APPSJSON
  cat >"$FIXTURE_AGENTS/com.example.appowned.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.appowned</string>
    <key>Program</key>
    <string>/Applications/AppOwned.app/Contents/MacOS/AppOwned</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
  cat >"$FIXTURE_AGENTS/com.example.arrayapp.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.arrayapp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ArrayApp.app/Contents/MacOS/ArrayApp</string>
        <string>--start-at-login</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
  cat >"$FIXTURE_AGENTS/com.example.foreignapp.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.foreignapp</string>
    <key>Program</key>
    <string>/usr/local/bin/something-else</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
}

converge() {
  local app="$1" out_file="$2" rc=0
  local _mock_dir
  _mock_dir="$(mktemp -d)"
  # Mock stat/dscl to return empty (no console user override of LAUNCHAGENTS_DIR)
  printf '#!/bin/sh\n' >"$_mock_dir/stat"
  chmod +x "$_mock_dir/stat"
  printf '#!/bin/sh\n' >"$_mock_dir/dscl"
  chmod +x "$_mock_dir/dscl"
  NUCLEUS_REPO_ROOT="$FIXTURE_ROOT" HOME="$FIXTURE_HOME" \
    PATH="$_mock_dir:$PATH" bash "$AUTOSTART_SH" disable "$app" \
    >"$out_file" 2>&1 || rc=$?
  rm -rf "$_mock_dir"
  printf '%s\n' "$rc"
}

test_scalar_program_plist_is_removed() {
  local rc=0
  make_fixture
  rc="$(converge AppOwned "$FIXTURE_ROOT/out.txt")"
  if [ "$rc" -eq 0 ] && [ ! -f "$FIXTURE_AGENTS/com.example.appowned.plist" ]; then
    assert_pass "an app-owned plist declaring a scalar Program is removed"
  else
    assert_fail "an app-owned plist declaring a scalar Program is removed" "rc=$rc plist still present: $([ -f "$FIXTURE_AGENTS/com.example.appowned.plist" ] && echo yes || echo no) output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_program_arguments_plist_is_removed() {
  local rc=0
  make_fixture
  rc="$(converge ArrayApp "$FIXTURE_ROOT/out.txt")"
  if [ "$rc" -eq 0 ] && [ ! -f "$FIXTURE_AGENTS/com.example.arrayapp.plist" ]; then
    assert_pass "an app-owned plist declaring ProgramArguments is still removed"
  else
    assert_fail "an app-owned plist declaring ProgramArguments is still removed" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_foreign_plist_is_kept() {
  local rc=0
  make_fixture
  rc="$(converge ForeignApp "$FIXTURE_ROOT/out.txt")"
  if [ "$rc" -eq 0 ] && [ -f "$FIXTURE_AGENTS/com.example.foreignapp.plist" ]; then
    assert_pass "a plist whose program points elsewhere is never removed"
  else
    assert_fail "a plist whose program points elsewhere is never removed" "rc=$rc plist present: $([ -f "$FIXTURE_AGENTS/com.example.foreignapp.plist" ] && echo yes || echo no) output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

if [ "$(uname -s)" != "Darwin" ]; then
  # The convergence path under test is the macOS login-item one; on other hosts the
  # XDG/registry branches run instead.
  assert_skip "app-owned LaunchAgent plist removal" "macOS-only convergence path"
  assert_skip "app-owned LaunchAgent ProgramArguments removal" "macOS-only convergence path"
  assert_skip "foreign LaunchAgent plist is preserved" "macOS-only convergence path"
else
  test_scalar_program_plist_is_removed
  test_program_arguments_plist_is_removed
  test_foreign_plist_is_kept
fi
finish_tests
