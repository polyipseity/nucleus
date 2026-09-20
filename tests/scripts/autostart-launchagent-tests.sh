#!/usr/bin/env bash
# Tests that app-autostart convergence removes an app-owned LaunchAgent plist in
# both plist forms, and leaves a foreign one alone.
#
# The regression this guards: parsing only the ProgramArguments array left an
# app-owned plist that declares the scalar <key>Program</key> (AltTab) registered,
# so the app started twice — once from its own agent and once from ours.
#
# Also guards FSKit file-system extensions: they are invisible to
# systemextensionsctl, and PluginKit rejects a module that is not inside a
# SIP-protected app, so they must be resolved through FSKit's own enabled-module
# list and reported as registered rather than as unapproved.
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
        "kind": "macos-launchagent",
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
        "kind": "macos-launchagent",
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
        "kind": "macos-launchagent",
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
  },
  "FSKitApp": {
    "displayName": "FSKit App",
    "description": "fixture app whose extension is an FSKit file-system module",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "autostartEnabled": true,
        "kind": "macos-system-extension",
        "bundleId": "io.macfuse.app.fsmodule.macfuse",
        "approvalInstructions": "fixture approval instructions"
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
  "ManualApp": {
    "displayName": "Manual App",
    "description": "fixture app with no mechanism a script can converge",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "kind": "manual",
        "path": "/Applications/ManualApp.app",
        "approvalInstructions": "fixture manual instructions"
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
  "MisplacedExtension": {
    "displayName": "Misplaced Extension",
    "description": "fixture app declaring a macOS-only kind on NixOS",
    "hosts": {
      "MacBook": {
        "platform": "macOS",
        "type": "omitted",
        "justification": "test fixture"
      },
      "NixOS": {
        "platform": "NixOS",
        "kind": "macos-system-extension",
        "bundleId": "io.example.misplaced",
        "approvalInstructions": "fixture misplacement instructions"
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

# run_autostart ACTION APP OUT_FILE [FSKIT_MODULE_LISTED] [HOST] — run one
# autostart action against the fixture repo with the macOS-only externals stubbed
# so the run is hermetic. FSKIT_MODULE_LISTED selects the FSKit enabled-module list
# the probe reads: "true" names the macFUSE module, "other" names a different
# module, and "false" leaves the list absent. Prints the exit status.
run_autostart() {
  local action="$1" app="$2" out_file="$3" fskit_module_listed="${4:-true}" host="${5:-}" rc=0
  local _mock_dir _fskit_dir
  _mock_dir="$(mktemp -d)"
  _fskit_dir="$FIXTURE_HOME/Library/Group Containers/group.com.apple.fskit.settings"
  # Mock stat/dscl to return empty (no console user override of LAUNCHAGENTS_DIR)
  printf '#!/bin/sh\n' >"$_mock_dir/stat"
  printf '#!/bin/sh\n' >"$_mock_dir/dscl"
  # Mock systemextensionsctl to report no extensions: FSKit modules never appear
  # there, so FSKit's enabled-module list is what resolves them.
  printf '#!/bin/sh\n' >"$_mock_dir/systemextensionsctl"
  case "$fskit_module_listed" in
  true)
    mkdir -p "$_fskit_dir"
    cat >"$_fskit_dir/enabledModules.plist" <<'FSKITLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>5</key>
    <string>io.macfuse.app.fsmodule.macfuse</string>
</dict>
</plist>
FSKITLIST
    ;;
  other)
    mkdir -p "$_fskit_dir"
    cat >"$_fskit_dir/enabledModules.plist" <<'FSKITLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>4</key>
    <string>io.example.other.fsmodule</string>
</dict>
</plist>
FSKITLIST
    ;;
  esac
  # Mock plutil to print the fixture list the way the probe reads it (a quoted
  # value per entry), and to fail on a missing file the way the real plutil does.
  cat >"$_mock_dir/plutil" <<'PLUTIL'
#!/bin/sh
[ -r "$2" ] || exit 1
sed -n 's|.*<string>\(.*\)</string>.*|  "value" => "\1"|p' "$2"
PLUTIL
  chmod +x "$_mock_dir/stat" "$_mock_dir/dscl" "$_mock_dir/systemextensionsctl" "$_mock_dir/plutil"
  local -a _env_prefix=(
    env
    NUCLEUS_REPO_ROOT="$FIXTURE_ROOT"
    HOME="$FIXTURE_HOME"
    PATH="$_mock_dir:$PATH"
  )
  # NUCLEUS_HOST pins the host so a platform-owned kind can be exercised on any
  # machine; without it the run resolves the host from uname.
  [ -n "$host" ] && _env_prefix+=(NUCLEUS_HOST="$host")
  "${_env_prefix[@]}" bash "$AUTOSTART_SH" "$action" "$app" >"$out_file" 2>&1 || rc=$?
  rm -rf "$_mock_dir"
  printf '%s\n' "$rc"
}

test_scalar_program_plist_is_removed() {
  local rc=0
  make_fixture
  rc="$(run_autostart disable AppOwned "$FIXTURE_ROOT/out.txt" true MacBook)"
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
  rc="$(run_autostart disable ArrayApp "$FIXTURE_ROOT/out.txt" true MacBook)"
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
  rc="$(run_autostart disable ForeignApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  if [ "$rc" -eq 0 ] && [ -f "$FIXTURE_AGENTS/com.example.foreignapp.plist" ]; then
    assert_pass "a plist whose program points elsewhere is never removed"
  else
    assert_fail "a plist whose program points elsewhere is never removed" "rc=$rc plist present: $([ -f "$FIXTURE_AGENTS/com.example.foreignapp.plist" ] && echo yes || echo no) output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_fskit_module_is_reported_present() {
  local rc=0
  make_fixture
  rc="$(run_autostart status FSKitApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  # Match the state column exactly: the literal 'enabled' also occurs in 'disabled'.
  if [ "$rc" -eq 0 ] && grep -Eq '^FSKitApp[[:space:]]+enabled[[:space:]]' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "an FSKit module listed in FSKit's enabled modules is reported enabled"
  else
    assert_fail "an FSKit module listed in FSKit's enabled modules is reported enabled" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_fskit_module_converge_skips_approval_instructions() {
  local rc=0
  make_fixture
  rc="$(run_autostart enable FSKitApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  if [ "$rc" -eq 0 ] &&
    grep -q 'FSKit module registered' "$FIXTURE_ROOT/out.txt" &&
    ! grep -q 'fixture approval instructions' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "converging an FSKit module listed in the enabled modules reports registration instead of approval instructions"
  else
    assert_fail "converging an FSKit module listed in the enabled modules reports registration instead of approval instructions" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_unregistered_fskit_module_keeps_approval_instructions() {
  local rc=0
  make_fixture
  rc="$(run_autostart enable FSKitApp "$FIXTURE_ROOT/out.txt" false MacBook)"
  if [ "$rc" -eq 0 ] && grep -q 'fixture approval instructions' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "an FSKit module without an enabled-module list keeps its approval instructions"
  else
    assert_fail "an FSKit module without an enabled-module list keeps its approval instructions" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

# The regression this guards: reading PluginKit for the module reported it absent
# even while it was registered and its volumes mounted, so convergence kept
# warning about an approval step that was already done. The list FSKit serves is
# the one a module has to appear in; a readable list that names another module is
# not evidence for this one.
test_unlisted_fskit_module_keeps_approval_instructions() {
  local rc=0
  make_fixture
  rc="$(run_autostart enable FSKitApp "$FIXTURE_ROOT/out.txt" other MacBook)"
  if [ "$rc" -eq 0 ] &&
    grep -q 'fixture approval instructions' "$FIXTURE_ROOT/out.txt" &&
    ! grep -q 'FSKit module registered' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "an FSKit module missing from an existing enabled-module list keeps its approval instructions"
  else
    assert_fail "an FSKit module missing from an existing enabled-module list keeps its approval instructions" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

# The manual-kind and misplacement cases are host-agnostic: they assert on the
# registry dispatch run with NUCLEUS_HOST pinned, so they also run off macOS.

test_manual_app_reports_approval_instructions() {
  local rc=0
  make_fixture
  rc="$(run_autostart enable ManualApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  if [ "$rc" -eq 0 ] && grep -q 'fixture manual instructions' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "a manual app reports its approval instructions and succeeds"
  else
    assert_fail "a manual app reports its approval instructions and succeeds" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_manual_app_status_shows_manual() {
  local rc=0
  make_fixture
  rc="$(run_autostart status ManualApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  if [ "$rc" -eq 0 ] && grep -Eq '^ManualApp[[:space:]]+manual[[:space:]]' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "a manual app reports state 'manual'"
  else
    assert_fail "a manual app reports state 'manual'" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_manual_app_verify_reports_no_drift() {
  local rc=0
  make_fixture
  rc="$(run_autostart verify ManualApp "$FIXTURE_ROOT/out.txt" true MacBook)"
  if [ "$rc" -eq 0 ] && ! grep -q 'drift' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "a manual app is never reported as drift"
  else
    assert_fail "a manual app is never reported as drift" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

test_macos_only_kind_is_rejected_off_macos() {
  local rc=0
  make_fixture
  rc="$(run_autostart enable MisplacedExtension "$FIXTURE_ROOT/out.txt" true NixOS)"
  # The regression: this entry used to fall through to a macOS-only branch and
  # print "System Settings → Privacy & Security" on a host that has neither.
  if [ "$rc" -ne 0 ] &&
    grep -q 'macOS-only' "$FIXTURE_ROOT/out.txt" &&
    ! grep -q 'Privacy & Security' "$FIXTURE_ROOT/out.txt"; then
    assert_pass "a macOS-only kind on a non-macOS host is rejected without macOS advice"
  else
    assert_fail "a macOS-only kind on a non-macOS host is rejected without macOS advice" "rc=$rc output=[$(cat "$FIXTURE_ROOT/out.txt")]"
  fi
  rm -rf "$FIXTURE_ROOT"
}

# The macOS login-item branch is exercised on every host: NUCLEUS_HOST pins the
# host, and run_autostart mocks plutil, stat, dscl, and systemextensionsctl, so the
# branch's own tool use is what the mocks answer. The product never calls
# launchctl on this path, so nothing here needs macOS. Running the cases
# everywhere is the point: a macOS-only suite that steps aside off macOS stops
# guarding the branch precisely where nobody is watching it.
test_scalar_program_plist_is_removed
test_program_arguments_plist_is_removed
test_foreign_plist_is_kept
test_fskit_module_is_reported_present
test_fskit_module_converge_skips_approval_instructions
test_unregistered_fskit_module_keeps_approval_instructions
test_unlisted_fskit_module_keeps_approval_instructions

test_manual_app_reports_approval_instructions
test_manual_app_status_shows_manual
test_manual_app_verify_reports_no_drift
test_macos_only_kind_is_rejected_off_macos

finish_tests
