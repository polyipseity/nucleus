#!/usr/bin/env bash
# Device detection library for CamillaDSP playback device selection.
# Sourced by camilladsp-daemon.sh and camilladsp-heartbeat.sh.
#
# Provides:
#   camilladsp_resolve_playback_device <config_file>
#     If devices.playback.device is non-null, passes config through unchanged.
#     If null, detects the system default output device, patches the YAML
#     in-memory, and writes the patched config to stdout.
#     The capture device (devices.capture.device) is always excluded from
#     detection — if the system default matches capture, it is skipped.
#
# Dependencies: python3 (yaml module), system_profiler (macOS), wpctl/pactl/aplay (Linux)
#
# State: entirely in-memory — no persistent cache file.
# Called once per config push (heartbeat tick or daemon initial push).
set -euo pipefail

_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$_LIB_DIR/../lib/lib.sh"
. "$_LIB_DIR/../lib/require-command.sh"
unset _LIB_DIR

# Helper: check if a command is available on PATH.
# Named to be recognized by the step 17 awk parser's local_funcs tracking.
_has_command() { command -v "$1" >/dev/null 2>&1; }

# --- Platform-specific default output detection ---

# macOS: parse system_profiler SPAudioDataType for the default output device.
_camilladsp_detect_macos() {
  local output
  output=$(system_profiler SPAudioDataType 2>/dev/null) || return 1

  local _tmpfile
  _tmpfile=$(mktemp) || return 1
  cat <<PYEOF >"$_tmpfile"
import sys
lines = sys.stdin.read().split('\n')
for i, line in enumerate(lines):
    if 'Default Output Device: Yes' in line:
        for j in range(i - 1, -1, -1):
            stripped = lines[j].rstrip()
            if stripped and not stripped.startswith(' ' * 6):
                name = stripped.strip().rstrip(':')
                if name:
                    print(name)
                    sys.exit(0)
        break
PYEOF
  python3 "$_tmpfile" <<< "$output" 2>/dev/null
  local _rc=$?
  rm -f "$_tmpfile"
  return $_rc
}

# Linux: try WirePlumber → PulseAudio → ALSA in order.
_camilladsp_detect_linux() {
  # WirePlumber
  if _has_command wpctl; then
    local default_sink
    default_sink=$(wpctl status 2>/dev/null \
      | grep -A1 'Sinks:' \
      | grep '\*' \
      | sed 's/.*\*\s*//' \
      | sed 's/\s\+[0-9]\+.*//')
    if [ -n "$default_sink" ]; then
      printf '%s\n' "$default_sink"
      return 0
    fi
  fi

  # PulseAudio
  if _has_command pactl; then
    local default_sink
    default_sink=$(pactl info 2>/dev/null \
      | grep 'Default Sink:' \
      | sed 's/Default Sink: //')
    if [ -n "$default_sink" ]; then
      printf '%s\n' "$default_sink"
      return 0
    fi
  fi

  # ALSA fallback: first card
  if _has_command aplay; then
    local first_card
    first_card=$(aplay -l 2>/dev/null \
      | grep '^card [0-9]' \
      | head -1 \
      | sed 's/card \([0-9]*\): .*/\1/')
    if [ -n "$first_card" ]; then
      printf '%s\n' "hw:CARD=${first_card},DEV=0"
      return 0
    fi
  fi

  return 1
}

camilladsp_detect_default_output() {
  case "$(uname -s)" in
    Darwin) _camilladsp_detect_macos ;;
    Linux)  _camilladsp_detect_linux ;;
    *)      return 1 ;;
  esac
}

# --- Fallback: first available device (not matching capture_device) ---

# macOS: enumerate all audio output devices, return the first non-capture one.
_camilladsp_detect_first_available_macos() {
  local capture_device="$1"
  local output
  output=$(system_profiler SPAudioDataType 2>/dev/null) || return 1

  local _tmpfile
  _tmpfile=$(mktemp) || return 1
  cat <<PYEOF >"$_tmpfile"
import sys
capture = sys.argv[1]
lines = sys.stdin.read().split('\n')
for i, line in enumerate(lines):
    stripped = line.rstrip()
    if stripped and not stripped.startswith('  ') and stripped.endswith(':'):
        name = stripped.rstrip(':').strip()
        if name and name != capture:
            print(name)
            sys.exit(0)
PYEOF
  python3 "$_tmpfile" "$capture_device" <<< "$output" 2>/dev/null
  local _rc=$?
  rm -f "$_tmpfile"
  return $_rc
}

# Linux: enumerate sinks via wpctl/aplay, return the first non-capture one.
_camilladsp_detect_first_available_linux() {
  local capture_device="$1"

  # WirePlumber
  if _has_command wpctl; then
    local first_sink
    first_sink=$(wpctl status 2>/dev/null \
      | grep -A20 'Sinks:' \
      | grep -E '^\s+[0-9]+\.' \
      | head -1 \
      | sed 's/^\s*[0-9]*\.\s*//' \
      | sed 's/\s\+[0-9]\+.*//')
    if [ -n "$first_sink" ] && [ "$first_sink" != "$capture_device" ]; then
      printf '%s\n' "$first_sink"
      return 0
    fi
  fi

  # PulseAudio
  if _has_command pactl; then
    local first_sink
    first_sink=$(pactl list sinks short 2>/dev/null \
      | head -1 \
      | awk '{print $2}')
    if [ -n "$first_sink" ] && [ "$first_sink" != "$capture_device" ]; then
      printf '%s\n' "$first_sink"
      return 0
    fi
  fi

  # ALSA fallback
  if _has_command aplay; then
    local first_card
    first_card=$(aplay -l 2>/dev/null \
      | grep '^card [0-9]' \
      | head -1 \
      | sed 's/card \([0-9]*\): .*/\1/')
    if [ -n "$first_card" ]; then
      printf '%s\n' "hw:CARD=${first_card},DEV=0"
      return 0
    fi
  fi

  return 1
}

camilladsp_detect_first_available() {
  local capture_device="$1"
  case "$(uname -s)" in
    Darwin) _camilladsp_detect_first_available_macos "$capture_device" ;;
    Linux)  _camilladsp_detect_first_available_linux "$capture_device" ;;
    *)      return 1 ;;
  esac
}

# --- Main resolve function ---

camilladsp_resolve_playback_device() {
  local config_file="$1"

  # Single Python call: read playback device and capture device in one pass.
  local _devices
  local _tmpfile
  _tmpfile=$(mktemp) || {
    cat "$config_file"
    return 0
  }
  cat <<PYEOF >"$_tmpfile"
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
playback = cfg.get('devices', {}).get('playback', {}).get('device', None)
capture = cfg.get('devices', {}).get('capture', {}).get('device', '') or ''
# null (None) = auto-detect signal; print empty string for shell -z check.
print(playback if playback is not None else '')
print(capture)
PYEOF
  _devices=$(python3 "$_tmpfile" "$config_file") || {
    rm -f "$_tmpfile"
    # Python/yaml unavailable — pass config through unchanged.
    cat "$config_file"
    return 0
  }
  rm -f "$_tmpfile"

  local playback_device capture_device
  playback_device=$(printf '%s' "$_devices" | head -1)
  capture_device=$(printf '%s' "$_devices" | tail -1)

  # Non-null playback device → pass through unchanged.
  if [ -n "$playback_device" ]; then
    cat "$config_file"
    return 0
  fi

  # Detect system default output device.
  local detected_device
  # check-suppress:suppression_doc: detection failure is non-fatal — falls through to fallback path
  detected_device=$(camilladsp_detect_default_output 2>/dev/null) || true

  # Hard invariant: if detected device matches capture device, reject it.
  # The capture device must never be used as playback — it would create
  # an audio loop (output → capture → processed → output again).
  if [ -n "$detected_device" ] && [ "$detected_device" = "$capture_device" ]; then
    detected_device=""
  fi

  # Fallback: first available device (not matching capture).
  if [ -z "$detected_device" ]; then
    # check-suppress:suppression_doc: detection failure is non-fatal — passes through with empty device
    detected_device=$(camilladsp_detect_first_available "$capture_device" 2>/dev/null) || true
  fi

  # Nothing available → pass through with empty device.
  if [ -z "$detected_device" ]; then
    cat "$config_file"
    return 0
  fi

  # Patch YAML in-memory: replace null playback device with detected device.
  local _patchfile
  _patchfile=$(mktemp) || {
    cat "$config_file"
    return 0
  }
  cat <<PYEOF >"$_patchfile"
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
cfg['devices']['playback']['device'] = sys.argv[2]
yaml.dump(cfg, sys.stdout, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
  python3 "$_patchfile" "$config_file" "$detected_device" 2>/dev/null || {
    rm -f "$_patchfile"
    # YAML patch failed — pass original config through.
    cat "$config_file"
    rm -f "$_patchfile"
    return 0
  }
  rm -f "$_patchfile"
}
