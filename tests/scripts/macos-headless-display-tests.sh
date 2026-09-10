#!/usr/bin/env bash
# Tests for the BetterDisplay headless virtual-screen specification:
#   macos-configure-headless-display.sh — the create path
#   macos-heartbeat-betterdisplay.sh     — the 60 s reconcile/recreate path
#   macos-display-resolutions.sh         — the exclusion that keeps the virtual
#                                          screen out of external-monitor matching
#
# The two create sites MUST agree on the virtual-screen parameters: the
# heartbeat recreates the screen with its own copy, so a stale value there
# silently undoes the create path on the next poll.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

PLATFORM_DIR="$SCRIPT_DIR/../../src/platforms/macOS/scripts"
CONFIGURE_SH="$PLATFORM_DIR/macos-configure-headless-display.sh"
HEARTBEAT_SH="$PLATFORM_DIR/macos-heartbeat-betterdisplay.sh"
RESOLUTIONS_SH="$PLATFORM_DIR/macos-display-resolutions.sh"

# multiplierStep x aspect is the logical size; -virtualScreenHiDPI doubles it
# into the framebuffer, so 80 x 16:10 = 1280x800 logical / 2560x1600 framebuffer.
EXPECTED_MULTIPLIER_STEP="80"

# Print every -multiplierStep value in a file, one per line, in source order.
_multiplier_steps_in() {
  local file="$1"
  grep -o -- '-multiplierStep=[0-9]*' "$file" | sed 's/.*=//'
}

# Count the -multiplierStep values in a file. More than one means a stale
# leftover value is still present and could be picked up by a future edit.
_multiplier_step_count() {
  _multiplier_steps_in "$1" | wc -l | tr -d ' '
}

# --- Tests ---

test_multiplier_step_value() {
  section 1 "multiplierStep value"

  local value
  value="$(_multiplier_steps_in "$CONFIGURE_SH")"
  if [ "$value" = "$EXPECTED_MULTIPLIER_STEP" ]; then
    assert_pass "headless-display create uses multiplierStep=$EXPECTED_MULTIPLIER_STEP"
  else
    assert_fail "headless-display create multiplierStep" \
      "expected '$EXPECTED_MULTIPLIER_STEP', got '$value'"
  fi

  value="$(_multiplier_steps_in "$HEARTBEAT_SH")"
  if [ "$value" = "$EXPECTED_MULTIPLIER_STEP" ]; then
    assert_pass "betterdisplay heartbeat uses multiplierStep=$EXPECTED_MULTIPLIER_STEP"
  else
    assert_fail "betterdisplay heartbeat multiplierStep" \
      "expected '$EXPECTED_MULTIPLIER_STEP', got '$value'"
  fi
}

test_create_sites_agree() {
  section 2 "create sites agree"

  local configure_count heartbeat_count
  configure_count="$(_multiplier_step_count "$CONFIGURE_SH")"
  heartbeat_count="$(_multiplier_step_count "$HEARTBEAT_SH")"

  if [ "$configure_count" = "1" ] && [ "$heartbeat_count" = "1" ]; then
    assert_pass "each create site declares exactly one multiplierStep"
  else
    assert_fail "multiplierStep declaration count" \
      "configure=$configure_count heartbeat=$heartbeat_count (expected 1 each)"
  fi

  local configure_steps heartbeat_steps
  configure_steps="$(_multiplier_steps_in "$CONFIGURE_SH" | sort -u)"
  heartbeat_steps="$(_multiplier_steps_in "$HEARTBEAT_SH" | sort -u)"
  if [ -n "$configure_steps" ] && [ "$configure_steps" = "$heartbeat_steps" ]; then
    assert_pass "both create sites use the identical multiplierStep ($configure_steps)"
  else
    assert_fail "create-site drift" \
      "configure='$configure_steps' heartbeat='$heartbeat_steps'"
  fi
}

test_hidpi_and_aspect_retained() {
  section 3 "HiDPI and aspect retained"

  if grep -q -- '-virtualScreenHiDPI=on' "$CONFIGURE_SH" &&
    grep -q -- '-virtualScreenHiDPI=on' "$HEARTBEAT_SH"; then
    assert_pass "both create sites keep -virtualScreenHiDPI=on"
  else
    assert_fail "HiDPI flag" "expected -virtualScreenHiDPI=on in both create sites"
  fi

  if grep -q -- '-aspectWidth=16' "$CONFIGURE_SH" &&
    grep -q -- '-aspectHeight=10' "$CONFIGURE_SH"; then
    assert_pass "create site keeps the 16:10 aspect"
  else
    assert_fail "aspect flags" "expected -aspectWidth=16 and -aspectHeight=10"
  fi
}

test_resolutions_skips_virtual_display() {
  section 4 "display-resolutions exclusion"

  if grep -q 'VIRTUAL_DISPLAY_SERIAL_ID="s2865085837"' "$RESOLUTIONS_SH"; then
    assert_pass "virtual-display serial id is pinned"
  else
    assert_fail "virtual-display serial id" \
      "expected VIRTUAL_DISPLAY_SERIAL_ID=s2865085837 in $RESOLUTIONS_SH"
  fi

  # The skip must live inside the external-display loop, otherwise a virtual
  # display is still matched and re-inflated.
  local loop_body
  loop_body="$(sed -n '/for ID in /,/^  done$/p' "$RESOLUTIONS_SH")"
  if printf '%s\n' "$loop_body" | grep -q 'VIRTUAL_DISPLAY_PERSISTENT_ID'; then
    assert_pass "external-display loop skips the virtual display"
  else
    assert_fail "virtual-display skip" \
      "no VIRTUAL_DISPLAY_PERSISTENT_ID check inside the external-display loop"
  fi

  if printf '%s\n' "$loop_body" | grep -q 'VIRTUAL_DISPLAY_SERIAL_ID'; then
    assert_pass "external-display loop also skips by serial id"
  else
    assert_fail "virtual-display serial skip" \
      "no VIRTUAL_DISPLAY_SERIAL_ID check inside the external-display loop"
  fi
}

# --- Run all tests ---

test_multiplier_step_value
test_create_sites_agree
test_hidpi_and_aspect_retained
test_resolutions_skips_virtual_display

echo ""
echo "--- macos-headless-display tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
