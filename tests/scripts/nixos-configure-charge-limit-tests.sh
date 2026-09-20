#!/usr/bin/env bash
# Tests for src/platforms/NixOS/scripts/nixos-configure-charge-limit.sh.
#
# The script converges the battery charge ceiling through plain sysfs writes.  It
# takes the power_supply class root as its argument, which is what lets the suite
# drive it end to end against a fixture tree — no root and no real battery — and
# assert what it leaves behind, including the failures it must not swallow.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CHARGE_LIMIT_SCRIPT="$SCRIPT_DIR/../../src/platforms/NixOS/scripts/nixos-configure-charge-limit.sh"
EXPECTED_END=80
EXPECTED_START=75

# make_battery <root> <name> [attribute...] — create a battery directory with the
# listed charge-control attributes seeded to a value the script has to change, so
# a run that never writes is visible.
make_battery() {
  local root="$1" name="$2"
  shift 2
  local attr
  mkdir -p "$root/$name"
  for attr in "$@"; do
    printf '%s\n' "100" >"$root/$name/$attr"
  done
}

# run_script <root> — run the charge-limit script against a fixture root, print
# its combined output, and return its exit status.
run_script() {
  bash "$CHARGE_LIMIT_SCRIPT" "$1" 2>&1
}

# read_value <path> — the value left behind, or empty when the file is missing.
read_value() {
  local path="$1" value=""
  if [ ! -e "$path" ]; then
    printf ''
    return 0
  fi
  if ! IFS= read -r value <"$path"; then
    printf ''
    return 0
  fi
  printf '%s' "$value"
}

# assert_value <test_name> <path> <expected>
assert_value() {
  local test_name="$1" path="$2" expected="$3" actual
  actual="$(read_value "$path")"
  if [ "$actual" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected [$expected] got [$actual] in $path"
  fi
}

# assert_status <test_name> <expected_status> <root>
assert_status() {
  local test_name="$1" expected="$2" root="$3" status=0
  bash "$CHARGE_LIMIT_SCRIPT" "$root" >/dev/null 2>&1 || status=$?
  if [ "$status" = "$expected" ]; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name" "expected exit $expected got $status"
  fi
}

test_converges_the_ceiling_and_the_resume_level() {
  local work
  work="$(mktemp -d)"
  make_battery "$work" BAT0 charge_control_end_threshold charge_control_start_threshold

  run_script "$work" >/dev/null

  assert_value "ceiling is set to $EXPECTED_END %" \
    "$work/BAT0/charge_control_end_threshold" "$EXPECTED_END"
  assert_value "resume level is set to $EXPECTED_START %" \
    "$work/BAT0/charge_control_start_threshold" "$EXPECTED_START"

  rm -rf "$work"
}

test_converges_every_battery() {
  local work
  work="$(mktemp -d)"
  make_battery "$work" BAT0 charge_control_end_threshold
  make_battery "$work" BAT1 charge_control_end_threshold charge_control_start_threshold
  # A non-battery supply must be left alone.
  mkdir -p "$work/AC"
  printf '%s\n' "1" >"$work/AC/online"

  run_script "$work" >/dev/null

  assert_value "first battery ceiling converges" "$work/BAT0/charge_control_end_threshold" "$EXPECTED_END"
  assert_value "second battery ceiling converges" "$work/BAT1/charge_control_end_threshold" "$EXPECTED_END"
  assert_value "second battery resume level converges" "$work/BAT1/charge_control_start_threshold" "$EXPECTED_START"
  assert_value "non-battery supply is untouched" "$work/AC/online" "1"

  rm -rf "$work"
}

test_writes_the_ceiling_when_the_resume_attribute_is_absent() {
  local work
  work="$(mktemp -d)"
  make_battery "$work" BAT0 charge_control_end_threshold

  run_script "$work" >/dev/null

  assert_value "ceiling is set without a resume attribute" \
    "$work/BAT0/charge_control_end_threshold" "$EXPECTED_END"
  if [ -e "$work/BAT0/charge_control_start_threshold" ]; then
    assert_fail "no resume attribute is invented" "the script created the attribute"
  else
    assert_pass "no resume attribute is invented"
  fi

  rm -rf "$work"
}

test_converges_upwards_from_a_lower_value() {
  local work
  work="$(mktemp -d)"
  mkdir -p "$work/BAT0"
  printf '%s\n' "60" >"$work/BAT0/charge_control_end_threshold"
  printf '%s\n' "50" >"$work/BAT0/charge_control_start_threshold"

  run_script "$work" >/dev/null

  assert_value "a lower ceiling is raised to $EXPECTED_END %" \
    "$work/BAT0/charge_control_end_threshold" "$EXPECTED_END"
  assert_value "a lower resume level is raised to $EXPECTED_START %" \
    "$work/BAT0/charge_control_start_threshold" "$EXPECTED_START"

  rm -rf "$work"
}

test_ignores_hardware_without_the_attribute() {
  local work output status=0
  work="$(mktemp -d)"
  mkdir -p "$work/BAT0"
  printf '%s\n' "100" >"$work/BAT0/capacity"

  output="$(run_script "$work")" || status=$?

  if [ "$status" -eq 0 ]; then
    assert_pass "unsupported hardware is not a failure"
  else
    assert_fail "unsupported hardware is not a failure" "exit $status"
  fi
  if printf '%s' "$output" | grep -q "not supported on this hardware"; then
    assert_pass "unsupported hardware is reported"
  else
    assert_fail "unsupported hardware is reported" "output [$output]"
  fi

  rm -rf "$work"
}

test_fails_when_the_write_is_refused() {
  local work
  work="$(mktemp -d)"
  # A directory in place of the attribute file makes the write fail for any uid,
  # including root, which is what a firmware-refused write looks like to the script.
  mkdir -p "$work/BAT0/charge_control_end_threshold"

  assert_status "a refused write fails activation" 1 "$work"

  rm -rf "$work"
}

test_fails_when_the_value_cannot_be_read_back() {
  local work
  work="$(mktemp -d)"
  mkdir -p "$work/BAT0"
  # WHY: a symlink to /dev/null accepts the write and then reports EOF, which is
  # the way to reach the read-back arm; a file that silently keeps a different
  # value cannot be built as a fixture.
  ln -s /dev/null "$work/BAT0/charge_control_end_threshold"

  assert_status "a value that cannot be read back fails activation" 1 "$work"

  rm -rf "$work"
}

test_fails_when_the_power_supply_root_is_missing() {
  local work
  work="$(mktemp -d)"

  assert_status "a missing power supply root fails activation" 1 "$work/absent"

  rm -rf "$work"
}

# ---- Charge-limit convergence ----

test_converges_the_ceiling_and_the_resume_level
test_converges_every_battery
test_writes_the_ceiling_when_the_resume_attribute_is_absent
test_converges_upwards_from_a_lower_value
test_ignores_hardware_without_the_attribute
test_fails_when_the_write_is_refused
test_fails_when_the_value_cannot_be_read_back
test_fails_when_the_power_supply_root_is_missing

finish_tests
