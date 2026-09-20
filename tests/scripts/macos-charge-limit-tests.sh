#!/usr/bin/env bash
# Tests for the charge-limit gate decisions in
# src/hosts/MacBook/scripts/macos-charge-limit.sh.
#
# Two independent gates are converged to the same 80 % ceiling, and a wrong
# decision is silent: either the native gate is skipped on a macOS that supports
# it, or a shortcut that is not the intended workflow is executed.  Both helpers
# are extracted and exercised against fixture input; the script body never runs,
# because it needs root, a console session, and the GUI Shortcuts helper, none of
# which CI provides.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CHARGE_LIMIT_SCRIPT="$SCRIPT_DIR/../../src/hosts/MacBook/scripts/macos-charge-limit.sh"
HOMEBREW_NIX="$SCRIPT_DIR/../../src/hosts/MacBook/homebrew.nix"
FLAKE_NIX="$SCRIPT_DIR/../../src/flake.nix"
ACTIVATION_NIX="$SCRIPT_DIR/../../src/hosts/MacBook/activation.nix"

NATIVE_GATE_MAJOR=26
NATIVE_GATE_MINOR=4
SHORTCUT_NAME="Set Charge Limit 80"

# Fail closed: a renamed helper would leave every case below running an empty
# function and asserting a meaningless verdict.
VERSION_FUNC="$(extract_func mcl_version_at_least "$CHARGE_LIMIT_SCRIPT")"
SHORTCUT_FUNC="$(extract_func mcl_shortcut_listed "$CHARGE_LIMIT_SCRIPT")"
PARSE_FUNC="$(extract_func mcl_parse_macos_version "$CHARGE_LIMIT_SCRIPT")"
if [ -z "$VERSION_FUNC" ] || [ -z "$SHORTCUT_FUNC" ] || [ -z "$PARSE_FUNC" ]; then
  assert_fail "charge-limit gate helpers are defined in the script" \
    "extract_func returned nothing from $CHARGE_LIMIT_SCRIPT"
  finish_tests
fi

# assert_supported <test_name> <expected> <major> <minor> — run the extracted
# version gate in a fresh shell and compare which side of the floor it reports.
assert_supported() {
  local test_name="$1" expected="$2" major="$3" minor="$4" actual
  actual="$(bash -c '
    eval "$1"
    shift
    if mcl_version_at_least "$@"; then printf supported; else printf unsupported; fi
  ' macos-charge-limit-tests "$VERSION_FUNC" "$major" "$minor" "$NATIVE_GATE_MAJOR" "$NATIVE_GATE_MINOR")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual]"
  fi
}

# assert_listed <test_name> <expected> <name> [listed lines...] — run the
# extracted matcher against a fixture `shortcuts list` body.
assert_listed() {
  local test_name="$1" expected="$2" name="$3" actual
  shift 3
  actual="$(
    for line in "$@"; do
      printf '%s\n' "$line"
    done | bash -c '
      eval "$1"
      shift
      if mcl_shortcut_listed "$@"; then printf present; else printf absent; fi
    ' macos-charge-limit-tests "$SHORTCUT_FUNC" "$name"
  )"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual]"
  fi
}

# assert_parse <test_name> <expected> <version> — run the extracted version
# parser in a fresh shell; expected is "<major> <minor>" or "rejected".
assert_parse() {
  local test_name="$1" expected="$2" version="$3" actual
  actual="$(bash -c '
    eval "$1"
    shift
    if parsed="$(mcl_parse_macos_version "$1")"; then printf "%s" "$parsed"; else printf rejected; fi
  ' macos-charge-limit-tests "$PARSE_FUNC" "$version")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual]"
  fi
}

test_native_gate_needs_macos_26_4_or_newer() {
  assert_supported "native gate is unsupported on macOS 15.0" unsupported 15 0
  assert_supported "native gate is unsupported on macOS 26.3" unsupported 26 3
  assert_supported "native gate is supported on macOS 26.4" supported 26 4
  assert_supported "native gate is supported on macOS 26.5" supported 26 5
  assert_supported "native gate is supported on macOS 27.0" supported 27 0
}

test_version_parsing_rejects_an_unusable_probe() {
  assert_parse "a three-part version reports major and minor" "15 6" "15.6.1"
  assert_parse "a two-part version reports major and minor" "26 4" "26.4"
  assert_parse "a bare major version reports minor zero" "26 0" "26"
  assert_parse "an empty version is rejected" rejected ""
  assert_parse "a leading dot is rejected" rejected ".4"
  assert_parse "a trailing dot is rejected" rejected "26."
  assert_parse "a non-numeric minor is rejected" rejected "26.x"
  assert_parse "a non-numeric major is rejected" rejected "abc"
}

test_shortcut_match_is_exact() {
  assert_listed "shortcut is found among other shortcuts" present "$SHORTCUT_NAME" \
    "Charge Overnight" "$SHORTCUT_NAME" "Disable Charge Limit"
  assert_listed "shortcut is found as the only entry" present "$SHORTCUT_NAME" "$SHORTCUT_NAME"
  assert_listed "an empty shortcut list does not report a match" absent "$SHORTCUT_NAME"
  assert_listed "a prefixed name does not report a match" absent "$SHORTCUT_NAME" \
    "Old $SHORTCUT_NAME"
  assert_listed "a suffixed name does not report a match" absent "$SHORTCUT_NAME" \
    "$SHORTCUT_NAME %"
  assert_listed "a truncated name does not report a match" absent "$SHORTCUT_NAME" \
    "Set Charge Limit 8"
}

test_bclm_fallback_is_gone() {
  # Parsing only, and allowed as such: these assert that a dead pattern is absent,
  # never that live code is present.
  local file
  for file in "$CHARGE_LIMIT_SCRIPT" "$HOMEBREW_NIX" "$FLAKE_NIX" "$ACTIVATION_NIX"; do
    if grep -q "bclm" "$file"; then
      assert_fail "bclm is absent from $(basename "$file")" "found a bclm reference"
    else
      assert_pass "bclm is absent from $(basename "$file")"
    fi
  done
}

# assert_invokes <pattern> — the script must still contain this literal
# invocation pattern.
assert_invokes() {
  local pattern="$1"
  if grep -qF "$pattern" "$CHARGE_LIMIT_SCRIPT"; then
    assert_pass "charge-limit script invokes [$pattern]"
  else
    assert_fail "charge-limit script invokes [$pattern]" "pattern not found"
  fi
}

test_both_gates_are_wired() {
  # WHY: parsing is the only check available here — the invocations themselves
  # need root, a console session, and the GUI Shortcuts helper.  These assertions
  # catch a gate being dropped from the script, not a wrong invocation.
  assert_invokes "maintain \"\$charge_limit_percent\""
  assert_invokes "/bin/launchctl asuser"
  assert_invokes "/usr/bin/shortcuts run"
}

test_invoked_system_binaries_exist() {
  # WHY: a wrong absolute path fails to exec at activation time, and that failure
  #   surfaces as the "helper unreachable" warning instead of an error, so the
  #   native gate would never converge while every other check stayed green.
  #   Each path is confirmed to be referenced first, so this list cannot rot into
  #   asserting nothing; provisioning-owned paths (/usr/local, /Applications) are
  #   deliberately absent because the script handles their absence itself.
  if [ "$(uname -s)" != "Darwin" ]; then
    assert_skip "system binaries the script invokes exist" "not macOS"
    return
  fi
  local path
  for path in /bin/launchctl /usr/bin/shortcuts /usr/bin/sudo /usr/bin/sw_vers; do
    if ! grep -qF "$path" "$CHARGE_LIMIT_SCRIPT"; then
      assert_fail "script still references [$path]" "not found in the script"
      continue
    fi
    if [ -x "$path" ]; then
      assert_pass "script invokes an existing binary [$path]"
    else
      assert_fail "script invokes an existing binary [$path]" "not executable"
    fi
  done
}

# ---- Charge-limit gates ----

test_native_gate_needs_macos_26_4_or_newer
test_version_parsing_rejects_an_unusable_probe
test_shortcut_match_is_exact
test_bclm_fallback_is_gone
test_both_gates_are_wired
test_invoked_system_binaries_exist

finish_tests
