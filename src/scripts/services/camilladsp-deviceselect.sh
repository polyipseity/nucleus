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
#     Fallback device selection is deterministic: the first non-capture device
#     is chosen by a case-sensitive ascending name ordering, matching the
#     Windows resolver.
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

# macOS: parse system_profiler SPAudioDataType -json for the default output device.
# Real system_profiler emits device flags as flat top-level keys and _properties
# as a string naming the default property. The default output device is the one
# whose coreaudio_default_audio_system_device == 'spaudio_yes'.
_camilladsp_detect_macos() {
  local output
  output=$(system_profiler SPAudioDataType -json 2>/dev/null) || return 1

  local _tmpfile
  _tmpfile=$(mktemp) || return 1
  cat <<PYEOF >"$_tmpfile"
import json, sys
for dev in json.loads(sys.stdin.read()).get('SPAudioDataType', []):
    for item in dev.get('_items', []):
        if item.get('coreaudio_default_audio_system_device') == 'spaudio_yes':
            print(item.get('_name', ''))
            sys.exit(0)
PYEOF
  python3 "$_tmpfile" <<<"$output" 2>/dev/null
  local _rc=$?
  rm -f "$_tmpfile"
  return $_rc
}

# Linux: try WirePlumber → PulseAudio → ALSA in order.
_camilladsp_detect_linux() {
  # WirePlumber
  if _has_command wpctl; then
    local default_sink
    default_sink=$(wpctl status 2>/dev/null |
      grep -A1 'Sinks:' |
      grep '\*' |
      sed 's/.*\*\s*//' |
      sed 's/\s\+[0-9]\+.*//')
    if [ -n "$default_sink" ]; then
      printf '%s\n' "$default_sink"
      return 0
    fi
  fi

  # PulseAudio
  if _has_command pactl; then
    local default_sink
    default_sink=$(pactl info 2>/dev/null |
      grep 'Default Sink:' |
      sed 's/Default Sink: //')
    if [ -n "$default_sink" ]; then
      printf '%s\n' "$default_sink"
      return 0
    fi
  fi

  # ALSA fallback: first card
  if _has_command aplay; then
    local first_card
    first_card=$(aplay -l 2>/dev/null |
      grep '^card [0-9]' |
      head -1 |
      sed 's/card \([0-9]*\): .*/\1/')
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
  Linux) _camilladsp_detect_linux ;;
  *) return 1 ;;
  esac
}

# --- Fallback: first available device (not matching capture_device) ---

# macOS: enumerate output-capable devices (presence of coreaudio_device_output),
# return the first non-capture one by deterministic case-sensitive ascending name ordering.
# Device flags are flat top-level keys on real system_profiler output.
_camilladsp_detect_first_available_macos() {
  local capture_device="$1"
  local output
  output=$(system_profiler SPAudioDataType -json 2>/dev/null) || return 1

  local _tmpfile
  _tmpfile=$(mktemp) || return 1
  cat <<PYEOF >"$_tmpfile"
import json, sys
capture = sys.argv[1]
for dev in json.loads(sys.stdin.read()).get('SPAudioDataType', []):
    for item in dev.get('_items', []):
        if 'coreaudio_device_output' not in item:
            continue  # input-only device (e.g. built-in mic)
        name = item.get('_name', '')
        if name and name != capture:
            print(name)
PYEOF
  local -a names
  mapfile -t names < <(python3 "$_tmpfile" "$capture_device" <<<"$output" 2>/dev/null)
  local _rc=$?
  rm -f "$_tmpfile"
  [ "${#names[@]}" -eq 0 ] && return $_rc
  printf '%s\n' "${names[@]}" | sort | head -1
}

# Linux: enumerate sinks via wpctl/pactl/aplay, return the first non-capture
# one by deterministic case-insensitive ascending name ordering.
_camilladsp_detect_first_available_linux() {
  local capture_device="$1"
  local -a candidates=()

  # WirePlumber
  if _has_command wpctl; then
    local sink
    while IFS= read -r sink; do
      [ -n "$sink" ] && [ "$sink" != "$capture_device" ] && candidates+=("$sink")
    done < <(wpctl status 2>/dev/null |
      grep -A20 'Sinks:' |
      grep -E '^\s+[0-9]+\.' |
      sed 's/^\s*[0-9]*\.\s*//' |
      sed 's/\s\+[0-9]\+.*//')
  fi

  # PulseAudio
  if _has_command pactl; then
    local sink
    while IFS= read -r sink; do
      [ -n "$sink" ] && [ "$sink" != "$capture_device" ] && candidates+=("$sink")
    done < <(pactl list sinks short 2>/dev/null |
      awk '{print $2}')
  fi

  # ALSA fallback
  if _has_command aplay; then
    local card
    while IFS= read -r card; do
      [ -n "$card" ] && candidates+=("hw:CARD=${card},DEV=0")
    done < <(aplay -l 2>/dev/null |
      grep '^card [0-9]' |
      sed 's/card \([0-9]*\): .*/\1/')
  fi

  [ "${#candidates[@]}" -eq 0 ] && return 1
  printf '%s\n' "${candidates[@]}" | sort | head -1
}

camilladsp_detect_first_available() {
  local capture_device="$1"
  case "$(uname -s)" in
  Darwin) _camilladsp_detect_first_available_macos "$capture_device" ;;
  Linux) _camilladsp_detect_first_available_linux "$capture_device" ;;
  *) return 1 ;;
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
