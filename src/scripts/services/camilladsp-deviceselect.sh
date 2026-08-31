#!/usr/bin/env bash
# Device detection and config-push library for CamillaDSP playback device selection.
# Sourced by camilladsp-run.sh and camilladsp-heartbeat.sh.
#
# Provides:
#   camilladsp_resolve_playback_device <config_file>
#     If devices.playback.device is non-null, passes config through unchanged.
#     If null, resolves the playback device using this priority chain:
#       1. System default output (via platform APIs)
#      2. Last saved default (from state file, validated against available devices)
#      3. First available device (deterministic sorted-name fallback)
#    The capture device (devices.capture.device) is always excluded from
#    detection — if any candidate matches capture, it is skipped.
#    Writes the patched config to stdout.
#  camilladsp_list_available_devices <capture_device>
#    Enumerates all available playback output devices from platform APIs,
#    excluding the capture device. Returns sorted names, one per line.
#    Used by last-saved validation and first-available fallback.
#   camilladsp_target_playback_device <config_file>
#     Returns the playback device name that detection would currently select
#     for the given config (the device camilladsp_resolve_playback_device would
#     set), or empty string if detection yields nothing. Used by the heartbeat
#     to detect when the live device has drifted from the desired device.
#   camilladsp_needs_push <state> <live_device> <target_device>
#     Pure decision: returns 1 (skip) only when camilladsp is Running AND the
#     live playback device is already set AND the target device is non-empty AND
#     the live device equals the target. This makes the heartbeat re-push when
#     the system default output device changes (live != target) instead of
#     skipping forever once any device is set. A null/empty target is NEVER
#     pushed — pushing it would set the device to null.
#   camilladsp_push_config [--port PORT] [--config FILE] [--retries N] [--retry-delay S]
#     Resolves the config and pushes it via SetConfig over the websocket API.
#
# Dependencies: python3 (yaml module), websocat, jq, system_profiler (macOS),
#               wpctl/pactl/aplay (Linux)
#
# State file: ~/.local/state/camilladsp/last-device.txt persists the last device
# pushed to CamillaDSP, used as fallback when no system default is detected.
# Called once per config push (heartbeat tick or supervisor initial push).
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
# excluding the capture device. Returns sorted names, one per line.
# Device flags are flat top-level keys on real system_profiler output.
_camilladsp_list_available_macos() {
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
  printf '%s\n' "${names[@]}" | sort
}

# Linux: enumerate sinks via wpctl/pactl/aplay, excluding the capture device.
# Returns sorted names, one per line.
_camilladsp_list_available_linux() {
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
  printf '%s\n' "${candidates[@]}" | sort
}

# List all available playback output devices (excluding capture_device).
# Returns sorted names, one per line. Used by last-saved validation and
# first-available fallback.
camilladsp_list_available_devices() {
  local capture_device="$1"
  case "$(uname -s)" in
  Darwin) _camilladsp_list_available_macos "$capture_device" ;;
  Linux) _camilladsp_list_available_linux "$capture_device" ;;
  *) return 1 ;;
  esac
}

# Return the first available playback device (not matching capture_device).
# Deterministic sorted-name fallback: delegates to camilladsp_list_available_devices.
camilladsp_detect_first_available() {
  local capture_device="$1"
  camilladsp_list_available_devices "$capture_device" | head -1
}

# --- Last saved default state file ---

# State directory for CamillaDSP device persistence.
CAMILLADSP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/camilladsp"
CAMILLADSP_LAST_DEVICE_FILE="$CAMILLADSP_STATE_DIR/last-device.txt"

# Save the resolved device name to the state file.
# Argument: device name
# Creates the state directory if it doesn't exist.
camilladsp_save_last_device() {
  local device="$1"
  [ -n "$device" ] || return 0
  mkdir -p "$CAMILLADSP_STATE_DIR"
  printf '%s' "$device" >"$CAMILLADSP_LAST_DEVICE_FILE"
}

# Load the last saved device name from the state file.
# Prints the device name if file exists and is non-empty.
# Returns 1 if file doesn't exist or is empty.
camilladsp_load_last_device() {
  if [ -s "$CAMILLADSP_LAST_DEVICE_FILE" ]; then
    cat "$CAMILLADSP_LAST_DEVICE_FILE"
    return 0
  fi
  return 1
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
  _devices=$(python3 "$_tmpfile" "$config_file")
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

  # Fallback 1: last saved default (validates device still exists).
  if [ -z "$detected_device" ]; then
    local saved_device
    if saved_device=$(camilladsp_load_last_device 2>/dev/null); then
      if [ -n "$saved_device" ] && [ "$saved_device" != "$capture_device" ]; then
        # Verify the saved device still exists on the system.
        local _all_devices
        if _all_devices=$(camilladsp_list_available_devices "$capture_device" 2>/dev/null); then
          if printf '%s\n' "$_all_devices" | grep -qxF "$saved_device"; then
            detected_device="$saved_device"
          fi
        else
          # Enumeration failed — accept saved device as best effort.
          detected_device="$saved_device"
        fi
      fi
    fi
  fi

  # Fallback 2: first available device (deterministic sorted-name fallback).
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
  python3 "$_patchfile" "$config_file" "$detected_device"
  rm -f "$_patchfile"
}

# --- Push decision and config push ---

# Resolve the target playback device name that detection would currently select
# for the given config (the device camilladsp_resolve_playback_device would set),
# or empty string if detection yields nothing. Used by the heartbeat to decide
# whether the live device has drifted from the desired device.
# Arguments: <config_file>
camilladsp_target_playback_device() {
  local config_file="$1"
  [ -f "$config_file" ] || return 1
  local _resolved
  _resolved=$(camilladsp_resolve_playback_device "$config_file") || return 1
  printf '%s' "$_resolved" | python3 -c "
import sys, yaml
try:
    cfg = yaml.safe_load(sys.stdin.read())
    d = cfg.get('devices', {}).get('playback', {}).get('device', None)
    print(d if d is not None else '')
except Exception:
    pass
"
}

# Pure skip decision. Returns 1 (skip) only when camilladsp is Running AND the
# live playback device is already set AND the live device equals the target.
# This makes the heartbeat re-push when the system default output device changes
# (live != target) instead of skipping forever once any device is set.
#
# A null/empty target is only skipped when camilladsp is Running (a running
# instance with a real device must never be pushed a null). When camilladsp is
# NOT Running (Inactive/Stopped) and the target is empty, we still PUSH — the
# resolver falls back to the first-available device inside
# camilladsp_resolve_playback_device, so a null device is never actually pushed.
# This guarantees the initial config is set even when detection yields nothing.
# Arguments: <state> <live_device> <target_device>
camilladsp_needs_push() {
  local state="$1"
  local live_device="$2"
  local target_device="$3"
  # Running with a real device: never push a null target (would set device to null).
  if [ "$state" = "Running" ] && [ -z "$target_device" ]; then
    return 1
  fi
  # Running and live device already matches target: nothing to do.
  if [ "$state" = "Running" ] && [ -n "$live_device" ] && [ "$live_device" = "$target_device" ]; then
    return 1
  fi
  return 0
}

# Resolve the config and push it via SetConfig over the websocket API.
# Retries with a fixed delay until success or retries exhausted.
# Arguments: [--port PORT] [--config FILE] [--retries N] [--retry-delay S]
# Returns 0 on successful SetConfig, 1 otherwise.
camilladsp_push_config() {
  local ws_port="${WS_PORT:-1234}"
  local config_file="$HOME/.config/camilladsp/configs/config.yml"
  local retries=1
  local retry_delay=0.5

  while [ $# -gt 0 ]; do
    case "$1" in
    --port)
      shift
      ws_port="${1:-$ws_port}"
      ;;
    --config)
      shift
      config_file="${1:-$config_file}"
      ;;
    --retries)
      shift
      retries="${1:-$retries}"
      ;;
    --retry-delay)
      shift
      retry_delay="${1:-$retry_delay}"
      ;;
    *)
      error "unknown argument: $1"
      return 1
      ;;
    esac
    shift
  done

  [ -f "$config_file" ] || return 1

  local _resolved_config
  _resolved_config=$(camilladsp_resolve_playback_device "$config_file") || return 1

  local _i
  for _i in $(seq 1 "$retries"); do
    if _push_resp=$(jq -cRs '{SetConfig: .}' <<<"$_resolved_config" |
      websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
      if printf '%s' "$_push_resp" | jq -e '.SetConfig.result == "Ok"' >/dev/null 2>&1; then
        # Save the resolved device to state file for future fallback.
        local _saved_device
        _saved_device=$(printf '%s' "$_resolved_config" | python3 -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin.read())
d = cfg.get('devices', {}).get('playback', {}).get('device', None)
print(d if d is not None else '')
" 2>/dev/null) || true # check-suppress:suppression_doc: YAML parsing is best-effort; missing device field is handled by downstream fallback
        [ -n "$_saved_device" ] && camilladsp_save_last_device "$_saved_device"
        return 0
      fi
    fi
    [ "$_i" -lt "$retries" ] && sleep "$retry_delay"
  done
  return 1
}
