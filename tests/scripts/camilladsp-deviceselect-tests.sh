#!/usr/bin/env bash
# Tests for src/scripts/services/camilladsp-deviceselect.sh —
# smart playback device detection for CamillaDSP.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

DEVICESELECT_SH="$SCRIPT_DIR/../../src/scripts/services/camilladsp-deviceselect.sh"

# Guard: python3 + yaml module required for all tests.
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found — skipping camilladsp-deviceselect tests"
  exit 0
fi
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "python3 yaml module not found — skipping camilladsp-deviceselect tests"
  exit 0
fi

# --- Helpers ---

# Create a minimal CamillaDSP config YAML with given playback and capture devices.
# Writes to a temp file and prints the path.
_make_config() {
  local playback_device="${1:-}"
  local capture_device="${2:-Loopback Audio}"
  local cfg
  cfg=$(mktemp) || return 1
  if [ -n "$playback_device" ]; then
    cat >"$cfg" <<YAML
---
devices:
  playback:
    channels: 2
    device: "$playback_device"
    type: CoreAudio
  capture:
    channels: 2
    device: "$capture_device"
    type: CoreAudio
YAML
  else
    cat >"$cfg" <<'YAML'
---
devices:
  playback:
    channels: 2
    device: null
    type: CoreAudio
  capture:
    channels: 2
    device: Loopback Audio
    type: CoreAudio
YAML
    # Override capture_device when using null template (heredoc cannot interpolate).
    if [ "$capture_device" != "Loopback Audio" ]; then
      local patched
      patched=$(mktemp) || return 1
      python3 -c "
import yaml, sys
with open('$cfg') as f:
    cfg = yaml.safe_load(f)
cfg['devices']['capture']['device'] = '$capture_device'
yaml.dump(cfg, open('$patched', 'w'), default_flow_style=False, sort_keys=False)
" 2>/dev/null || {
        rm -f "$patched"
        rm -f "$cfg"
        return 1
      }
      mv "$patched" "$cfg"
    fi
  fi
  printf '%s' "$cfg"
}

# Source the deviceselect library in a subshell context so mock overrides
# don't leak into the test runner. All test functions use _run_resolve which
# forks a bash subshell that sources the library, applies mocks, then calls
# camilladsp_resolve_playback_device.
#
# Mock globals set by each test before calling _run_resolve:
#   _MOCK_DEFAULT_OUTPUT  — value for camilladsp_detect_default_output
#   _MOCK_FIRST_AVAILABLE — value for camilladsp_detect_first_available
#   _MOCK_DEFAULT_RC      — return code for camilladsp_detect_default_output (default 0)
#   _MOCK_FIRST_RC        — return code for camilladsp_detect_first_available (default 0)

_MOCK_DEFAULT_OUTPUT=""
_MOCK_FIRST_AVAILABLE=""
_MOCK_DEFAULT_RC=0
_MOCK_FIRST_RC=0

# Run resolve in a subshell with mocked detection functions.
# $1 = config file path. Prints resolved config to stdout.
_run_resolve() {
  local config_file="$1"
  bash -c '
    _lib_script="$1"
    _mock_default="$2"
    _mock_default_rc="$3"
    _mock_first="$4"
    _mock_first_rc="$5"
    _config_file="$6"
    . "$_lib_script"
    # Override detection functions with mocks (use variables, not positional params).
    camilladsp_detect_default_output() {
      printf "%s" "$_mock_default"
      return "$_mock_default_rc"
    }
    camilladsp_detect_first_available() {
      printf "%s" "$_mock_first"
      return "$_mock_first_rc"
    }
    camilladsp_resolve_playback_device "$_config_file"
  ' _ "$DEVICESELECT_SH" \
    "$_MOCK_DEFAULT_OUTPUT" "$_MOCK_DEFAULT_RC" \
    "$_MOCK_FIRST_AVAILABLE" "$_MOCK_FIRST_RC" \
    "$config_file"
}

# Extract playback.device from a YAML string on stdin.
_extract_playback_device() {
  python3 -c "
import yaml, sys
cfg = yaml.safe_load(sys.stdin.read())
playback = cfg.get('devices', {}).get('playback', {}).get('device', None)
print(playback if playback is not None else '')
"
}

# Extract playback.type from a YAML string on stdin (verify non-playback fields survive).
_extract_playback_type() {
  python3 -c "
import yaml, sys
cfg = yaml.safe_load(sys.stdin.read())
print(cfg.get('devices', {}).get('playback', {}).get('type', ''))
"
}

# --- Tests ---

# Test 1: Non-empty playback device → pass through unchanged.
test_passthrough_nonempty_device() {
  local cfg
  cfg="$(_make_config 'MacBook Pro Speakers' 'Loopback Audio')"
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ "$device" = "MacBook Pro Speakers" ]; then
    assert_pass "non-empty playback device passes through unchanged"
  else
    assert_fail "non-empty playback device passthrough" "expected 'MacBook Pro Speakers', got '$device'"
  fi
}

# Test 2: Null playback device + default output available → patch with detected device.
test_patches_with_default_output() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT="External USB DAC"
  _MOCK_FIRST_AVAILABLE=""
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ "$device" = "External USB DAC" ]; then
    assert_pass "null device patched with detected default output"
  else
    assert_fail "null device patching" "expected 'External USB DAC', got '$device'"
  fi
}

# Test 3: Default output = capture device → rejects capture, uses fallback.
test_rejects_capture_device() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT="Loopback Audio"
  _MOCK_FIRST_AVAILABLE="MacBook Pro Speakers"
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ "$device" = "MacBook Pro Speakers" ]; then
    assert_pass "capture device rejected, fallback used"
  else
    assert_fail "capture device rejection" "expected 'MacBook Pro Speakers', got '$device'"
  fi
}

# Test 4: No default output, no fallback devices → pass through with null device.
test_null_when_no_devices() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT=""
  _MOCK_DEFAULT_RC=1
  _MOCK_FIRST_AVAILABLE=""
  _MOCK_FIRST_RC=1
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ -z "$device" ]; then
    assert_pass "null device preserved when no devices available"
  else
    assert_fail "no-devices passthrough" "expected empty, got '$device'"
  fi
}

# Test 5: Non-playback fields survive YAML round-trip.
test_preserves_other_fields() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT="USB Speaker"
  _MOCK_FIRST_AVAILABLE=""
  local resolved
  resolved=$(_run_resolve "$cfg")
  local ptype
  ptype=$(_extract_playback_type <<<"$resolved")
  rm -f "$cfg"
  if [ "$ptype" = "CoreAudio" ]; then
    assert_pass "non-playback fields preserved after patching"
  else
    assert_fail "field preservation" "expected 'CoreAudio', got '$ptype'"
  fi
}

# Test 6: Default output = capture AND fallback returns empty (all devices are capture).
# camilladsp_detect_first_available's contract is to exclude the capture device;
# when every device is the capture device, it returns empty.
test_all_devices_are_capture() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT="Loopback Audio"
  _MOCK_FIRST_AVAILABLE=""
  _MOCK_FIRST_RC=1
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ -z "$device" ]; then
    assert_pass "null device when all available devices match capture"
  else
    assert_fail "all-capture fallback" "expected empty, got '$device'"
  fi
}

# Test 7: No default output (rc 1) but first-available returns a device →
# deterministic fallback selection picks that device. This is the scenario where
# no audio device is the system default but autodetection must still pick one.
test_no_default_fallback_first_available() {
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT=""
  _MOCK_DEFAULT_RC=1
  _MOCK_FIRST_AVAILABLE="USB Speaker"
  _MOCK_FIRST_RC=0
  local resolved
  resolved=$(_run_resolve "$cfg")
  local device
  device=$(_extract_playback_device <<<"$resolved")
  rm -f "$cfg"
  if [ "$device" = "USB Speaker" ]; then
    assert_pass "no default → first non-capture fallback selected deterministically"
  else
    assert_fail "no-default fallback" "expected 'USB Speaker', got '$device'"
  fi
}

# Test 8: real macOS JSON parsing — default output detection via system_profiler -json.
# Fixture mirrors the REAL system_profiler SPAudioDataType -json shape: _properties
# is a STRING (naming the default property) and device flags are FLAT top-level
# keys on each item. The buggy code assumed _properties was a dict and read flags
# from it, which raised on the real shape.
test_macos_json_default_output() {
  local json
  json=$(
    cat <<'JSON'
{
  "SPAudioDataType": [
    {
      "_items": [
        { "_name": "BlackHole 2ch", "_properties": "coreaudio_default_audio_system_device", "coreaudio_default_audio_system_device": "spaudio_yes", "coreaudio_device_output": 2 },
        { "_name": "MacBook Air喇叭", "_properties": "coreaudio_device_output", "coreaudio_device_output": 2 },
        { "_name": "MacBook Air咪高風", "_properties": "coreaudio_device_input", "coreaudio_device_input": 1 }
      ],
      "_name": "coreaudio_device"
    }
  ]
}
JSON
  )
  local result
  result=$(bash -c '
    _lib_script="$1"
    _json="$2"
    . "$_lib_script"
    system_profiler() { printf "%s" "$_json"; }
    _camilladsp_detect_macos
  ' _ "$DEVICESELECT_SH" "$json")
  if [ "$result" = "BlackHole 2ch" ]; then
    assert_pass "macOS JSON default output detection"
  else
    assert_fail "macOS JSON default output" "expected 'BlackHole 2ch', got '$result'"
  fi
}

# Test 9: real macOS JSON fallback — output-only filtering + case-sensitive ordering.
# Includes an input-only mic (excluded), the capture device (excluded), and two
# output devices whose case-sensitive vs case-insensitive ordering differs
# ("Banana" < "apple" case-sensitively, the reverse case-insensitively).
# Fixture uses the REAL shape: string _properties + flat top-level keys.
test_macos_json_first_available() {
  local json
  json=$(
    cat <<'JSON'
{
  "SPAudioDataType": [
    {
      "_items": [
        { "_name": "BlackHole 2ch", "_properties": "coreaudio_device_output", "coreaudio_device_output": 2 },
        { "_name": "apple", "_properties": "coreaudio_device_output", "coreaudio_device_output": 2 },
        { "_name": "Banana", "_properties": "coreaudio_device_output", "coreaudio_device_output": 2 },
        { "_name": "MacBook Air咪高風", "_properties": "coreaudio_device_input", "coreaudio_device_input": 1 }
      ],
      "_name": "coreaudio_device"
    }
  ]
}
JSON
  )
  local result
  result=$(bash -c '
    _lib_script="$1"
    _json="$2"
    _capture="$3"
    . "$_lib_script"
    system_profiler() { printf "%s" "$_json"; }
    _camilladsp_detect_first_available_macos "$_capture"
  ' _ "$DEVICESELECT_SH" "$json" "BlackHole 2ch")
  # Case-sensitive ascending: "Banana" (B=66) precedes "apple" (a=97); mic and
  # capture are excluded. Expecting "Banana" proves case-sensitive ordering.
  if [ "$result" = "Banana" ]; then
    assert_pass "macOS JSON fallback excludes input-only and capture, case-sensitive"
  else
    assert_fail "macOS JSON fallback" "expected 'Banana', got '$result'"
  fi
}

# Test 10: real-shape regression — default output detection against a fixture
# byte-identical in shape to actual `system_profiler SPAudioDataType -json` on a
# MacBook: string _properties, flat keys, a default output device, a built-in
# output device, and an input-only mic with no coreaudio_device_output. Guards
# against the dict-_properties assumption that broke real detection.
test_macos_real_shape_default_output() {
  local json
  json=$(
    cat <<'JSON'
{
  "SPAudioDataType": [
    {
      "_items": [
        { "_name": "BlackHole 2ch", "_properties": "coreaudio_default_audio_system_device", "coreaudio_default_audio_output_device": "spaudio_yes", "coreaudio_default_audio_system_device": "spaudio_yes", "coreaudio_device_input": 2, "coreaudio_device_output": 2, "coreaudio_device_srate": 96000, "coreaudio_device_transport": "coreaudio_device_type_virtual" },
        { "_name": "MacBook Air咪高風", "_properties": "coreaudio_default_audio_input_device", "coreaudio_default_audio_input_device": "spaudio_yes", "coreaudio_device_input": 1, "coreaudio_device_srate": 48000, "coreaudio_device_transport": "coreaudio_device_type_builtin" },
        { "_name": "MacBook Air喇叭", "_properties": "coreaudio_device_output", "coreaudio_device_output": 2, "coreaudio_device_srate": 96000, "coreaudio_device_transport": "coreaudio_device_type_builtin" }
      ],
      "_name": "coreaudio_device"
    }
  ]
}
JSON
  )
  local result
  result=$(bash -c '
    _lib_script="$1"
    _json="$2"
    . "$_lib_script"
    system_profiler() { printf "%s" "$_json"; }
    _camilladsp_detect_macos
  ' _ "$DEVICESELECT_SH" "$json")
  if [ "$result" = "BlackHole 2ch" ]; then
    assert_pass "macOS real-shape default output detection"
  else
    assert_fail "macOS real-shape default output" "expected 'BlackHole 2ch', got '$result'"
  fi
}

# Test 11: skip-decision invariant — a null live device on a running instance
# must NEVER be skipped (it must be pushed). This is the regression guard for
# the broken "skip when Running" logic that let a null device stick forever.
# The decision now also re-pushes when the live device differs from the target
# (the device detection would currently select) — i.e. when the system default
# output device changes. A null target is never pushed.
test_needs_push_decision() {
  # Format: state|live|target|expected  (expected = skip or push)
  local cases=(
    "Running|MacBook Air喇叭|MacBook Air喇叭|skip" # Running + live==target → skip
    "Running|MacBook Air喇叭||skip"              # Running + null target → skip (never push null)
    "Running||MacBook Air喇叭|push"              # Running + null live + non-null target → push
    "Running|Old Device|MacBook Air喇叭|push"    # Running + live != target → push (default changed)
    "Stopped|MacBook Air喇叭|MacBook Air喇叭|push" # not Running → push
    "|MacBook Air喇叭|MacBook Air喇叭|push"        # empty state → push
    "Inactive|||push"                          # not Running + empty target → push (initial config set even when detection yields nothing)
    "Running|U18||skip"                        # Running + null target → skip (never push null onto a running instance)
  )
  local all_ok=1
  for c in "${cases[@]}"; do
    local state live target expected
    state="${c%%|*}"
    c="${c#*|}"
    live="${c%%|*}"
    c="${c#*|}"
    target="${c%%|*}"
    expected="${c#*|}"
    # camilladsp_needs_push returns 1 (skip) or 0 (push). Capture the rc
    # inside a subshell so the non-zero skip return doesn't trip set -e.
    local rc
    rc=$(
      bash -c '
      _lib_script="$1"
      _state="$2"
      _live="$3"
      _target="$4"
      . "$_lib_script"
      camilladsp_needs_push "$_state" "$_live" "$_target"
    ' _ "$DEVICESELECT_SH" "$state" "$live" "$target"
      echo $?
    )
    local got
    got=$([ "$rc" -eq 1 ] && printf 'skip' || printf 'push')
    if [ "$got" != "$expected" ]; then
      all_ok=0
      assert_fail "needs_push($state,$live,$target)" "expected '$expected', got '$got'"
    fi
  done
  if [ "$all_ok" -eq 1 ]; then
    assert_pass "skip-decision re-pushes when live device differs from target"
  fi
}

# Test 12: target device helper — returns the device detection would currently
# select (the device camilladsp_resolve_playback_device would set), or empty
# when detection yields nothing. This is what the heartbeat compares against.
test_target_playback_device() {
  # Null playback device + default output available → target is the detected device.
  local cfg
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT="External USB DAC"
  _MOCK_FIRST_AVAILABLE=""
  local target
  target=$(bash -c '
    _lib_script="$1"
    _cfg="$2"
    _mock_default="$3"
    _mock_first="$4"
    . "$_lib_script"
    camilladsp_detect_default_output() { printf "%s" "$_mock_default"; return 0; }
    camilladsp_detect_first_available() { printf "%s" "$_mock_first"; return 0; }
    camilladsp_target_playback_device "$_cfg"
  ' _ "$DEVICESELECT_SH" "$cfg" "$_MOCK_DEFAULT_OUTPUT" "$_MOCK_FIRST_AVAILABLE")
  rm -f "$cfg"
  if [ "$target" = "External USB DAC" ]; then
    assert_pass "target helper returns detected default output"
  else
    assert_fail "target helper default output" "expected 'External USB DAC', got '$target'"
  fi

  # Non-null playback device → target is the explicit device (pass-through).
  cfg="$(_make_config "MacBook Pro Speakers" "Loopback Audio")"
  target=$(bash -c '
    _lib_script="$1"
    _cfg="$2"
    . "$_lib_script"
    camilladsp_target_playback_device "$_cfg"
  ' _ "$DEVICESELECT_SH" "$cfg")
  rm -f "$cfg"
  if [ "$target" = "MacBook Pro Speakers" ]; then
    assert_pass "target helper returns explicit playback device"
  else
    assert_fail "target helper explicit device" "expected 'MacBook Pro Speakers', got '$target'"
  fi

  # No devices available → target is empty (never push a null device).
  cfg="$(_make_config "" "Loopback Audio")"
  _MOCK_DEFAULT_OUTPUT=""
  _MOCK_DEFAULT_RC=1
  _MOCK_FIRST_AVAILABLE=""
  _MOCK_FIRST_RC=1
  target=$(bash -c '
    _lib_script="$1"
    _cfg="$2"
    _mock_default="$3"
    _mock_default_rc="$4"
    _mock_first="$5"
    _mock_first_rc="$6"
    . "$_lib_script"
    camilladsp_detect_default_output() { printf "%s" "$_mock_default"; return "$_mock_default_rc"; }
    camilladsp_detect_first_available() { printf "%s" "$_mock_first"; return "$_mock_first_rc"; }
    camilladsp_target_playback_device "$_cfg"
  ' _ "$DEVICESELECT_SH" "$cfg" "$_MOCK_DEFAULT_OUTPUT" "$_MOCK_DEFAULT_RC" "$_MOCK_FIRST_AVAILABLE" "$_MOCK_FIRST_RC")
  rm -f "$cfg"
  if [ -z "$target" ]; then
    assert_pass "target helper returns empty when no devices available"
  else
    assert_fail "target helper no devices" "expected empty, got '$target'"
  fi
}

# --- Run all tests ---

test_needs_push_decision
test_target_playback_device

test_macos_json_default_output
test_macos_json_first_available
test_macos_real_shape_default_output

test_no_default_fallback_first_available

test_passthrough_nonempty_device
test_patches_with_default_output
test_rejects_capture_device
test_null_when_no_devices
test_preserves_other_fields
test_all_devices_are_capture

echo ""
echo "--- camilladsp-deviceselect tests: $TESTS_PASSED passed, $TESTS_FAILED failed ---"
echo ""

exit "$TESTS_FAILED"
