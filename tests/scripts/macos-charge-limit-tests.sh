#!/usr/bin/env bash
# Tests for the charge-limit convergence in
# src/hosts/MacBook/scripts/macos-charge-limit.sh.
#
# The script converges exactly one gate: the `battery` CLI, which writes the
# firmware-level SMC charging gate.  Two failures would be silent — the gate
# being dropped from the script, and the user-dependent Shortcuts path being
# reintroduced, which would put a hand-built shortcut back into the apply path.
# Both are asserted by parsing; the script body never runs, because it needs root
# and a console session, which CI does not provide.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CHARGE_LIMIT_SCRIPT="$SCRIPT_DIR/../../src/hosts/MacBook/scripts/macos-charge-limit.sh"
MANUAL_MD="$SCRIPT_DIR/../../src/hosts/MacBook/MANUAL.md"
HOMEBREW_NIX="$SCRIPT_DIR/../../src/hosts/MacBook/homebrew.nix"
FLAKE_NIX="$SCRIPT_DIR/../../src/flake.nix"
ACTIVATION_NIX="$SCRIPT_DIR/../../src/hosts/MacBook/activation.nix"

# assert_invokes <pattern> — the script must contain this literal, so a dropped
# invocation cannot pass unnoticed.
assert_invokes() {
  local pattern="$1"
  if grep -qF "$pattern" "$CHARGE_LIMIT_SCRIPT"; then
    assert_pass "charge-limit script invokes [$pattern]"
  else
    assert_fail "charge-limit script invokes [$pattern]" "pattern not found"
  fi
}

# assert_absent <file> <pattern> <description> — the pattern must not appear.
# WHY: parsing is allowed here because these patterns are code paths, not
#   present-in-source assertions: the invocation that would be reintroduced
#   cannot be exercised without root plus the GUI Shortcuts helper.
assert_absent() {
  local file="$1" pattern="$2" description="$3"
  if [ ! -f "$file" ]; then
    # WHY: grep exits 2 for a missing file, which would land in the "absent"
    #   branch below and pass a guard whose file was renamed or moved.
    assert_fail "$description" "file not found: $file"
    return
  fi
  if grep -qF "$pattern" "$file"; then
    assert_fail "$description" "[$pattern] found in $(basename "$file")"
  else
    assert_pass "$description"
  fi
}

test_bclm_fallback_is_gone() {
  # Parsing only, and allowed as such: these assert that a dead pattern is absent,
  # never that live code is present.
  local file
  for file in "$CHARGE_LIMIT_SCRIPT" "$HOMEBREW_NIX" "$FLAKE_NIX" "$ACTIVATION_NIX"; do
    assert_absent "$file" "bclm" "bclm is absent from $(basename "$file")"
  done
}

# WHY: `charge_limit_percent=80` is the value the gate converges, and the literal
#   invocation is what actually writes the firmware gate; neither can be
#   exercised here (they need root plus the helper), so a rename or a dropped
#   call would otherwise be invisible.
test_firmware_gate_is_wired() {
  assert_invokes 'charge_limit_percent=80'
  # shellcheck disable=SC2016 # reason: the literal invocation is under test, not a shell expansion
  assert_invokes 'maintain "$charge_limit_percent"'
}

test_shortcuts_gate_is_not_reintroduced() {
  local pattern
  for pattern in "/usr/bin/shortcuts" "/bin/launchctl" "sw_vers" "native_charge_limit"; do
    assert_absent "$CHARGE_LIMIT_SCRIPT" "$pattern" \
      "the removed Shortcuts gate [$pattern] stays out of the script"
  done
}

test_manual_does_not_ask_for_a_shortcut() {
  local pattern
  for pattern in "shortcuts list" "Set Battery Charge Limit" "Set Charge Limit 80"; do
    assert_absent "$MANUAL_MD" "$pattern" \
      "MANUAL.md no longer asks for a shortcut [$pattern]"
  done
}

test_invoked_system_binaries_exist() {
  # WHY: a wrong absolute path fails to exec at activation time, so the gate
  #   would never converge while every other check stayed green.  Each path is
  #   confirmed to be referenced first, so this list cannot rot into asserting
  #   nothing; provisioning-owned paths (/usr/local, /Applications) are
  #   deliberately absent because the script handles their absence itself.
  if [ "$(uname -s)" != "Darwin" ]; then
    assert_skip "system binaries the script invokes exist" "not macOS"
    return
  fi
  local path
  path=/usr/bin/sudo
  if ! grep -qF "$path" "$CHARGE_LIMIT_SCRIPT"; then
    assert_fail "script still references [$path]" "not found in the script"
  elif [ -x "$path" ]; then
    assert_pass "script invokes an existing binary [$path]"
  else
    assert_fail "script invokes an existing binary [$path]" "not executable"
  fi
}

# ---- Charge limit ----

test_bclm_fallback_is_gone
test_firmware_gate_is_wired
test_shortcuts_gate_is_not_reintroduced
test_manual_does_not_ask_for_a_shortcut
test_invoked_system_binaries_exist

finish_tests
