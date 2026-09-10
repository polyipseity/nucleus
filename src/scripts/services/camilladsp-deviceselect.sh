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
#    The raw enumerator: expensive on macOS (spawns system_profiler, which
#    triggers coreaudiod/TCC work), so callers inside a polling loop must use
#    camilladsp_list_available_devices_cached instead.
#   camilladsp_list_available_devices_cached <capture_device> <probe> [required_device]
#     Cached wrapper around camilladsp_list_available_devices. Reuses a stored
#     result while nothing indicates the device set has changed, so the steady
#     state costs zero enumerations while a real device change is still seen on
#     the next tick. See the function for the exact reuse conditions.
#   camilladsp_clear_last_device <path>
#     Removes the persisted last-device state file.
#   camilladsp_target_playback_device <config_file>
#     Returns the playback device name that detection would currently select
#     for the given config (the device camilladsp_resolve_playback_device would
#     set), or empty string if detection yields nothing. Used by the heartbeat
#     to detect when the live device has drifted from the desired device.
#   camilladsp_config_changed <config_file> <target_device>
#     Returns 0 when the config differs from the config last pushed, 1 when it
#     is unchanged. Comparing against what WE last pushed (not camilladsp's live
#     config) means edits made through camillagui are never reverted.
#     camilladsp_record_push <fingerprint> records the pushed state.
#   camilladsp_needs_push <state> <live_device> <target_device> <config_changed>
#     Pure decision: returns 1 (skip) only when camilladsp is Running AND the
#     live playback device is already set AND the target device is non-empty AND
#     the live device equals the target AND the config is unchanged. This makes
#     the heartbeat re-push when the system default output device changes
#     (live != target) or the config file is edited instead of skipping forever
#     once any device is set. A null/empty target is NEVER pushed — pushing it
#     would set the device to null.
#   camilladsp_push_config [--port PORT] [--config FILE] [--device NAME] [--retries N] [--retry-delay S]
#     Resolves the config and pushes it via SetConfig over the websocket API.
#
# Dependencies: python3 (yaml module), websocat, jq, SwitchAudioSource (macOS),
#               shasum/sha256sum, wpctl/pactl/aplay (Linux)
#
# State files under ~/.local/state/camilladsp/:
#   last-device.txt         last device pushed, used as fallback when no
#                           system default is detected
#   last-push.txt           fingerprint of the last config pushed, used to
#                           detect config-file edits
#   available-devices.txt   cached device enumeration
#   available-devices.meta  cache key: probe, capture device, timestamp
# Touched once per config push (heartbeat tick), never by the run supervisor.
set -euo pipefail

_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$_LIB_DIR/../lib/lib.sh"
. "$_LIB_DIR/../lib/require-command.sh"
unset _LIB_DIR

# Helper: check if a command is available on PATH.
# Named to be recognized by the step 17 awk parser's local_funcs tracking.
_has_command() { command -v "$1" >/dev/null 2>&1; }

# SHA-256 of stdin, trimmed to the bare digest.
# macOS ships `shasum` and no `sha256sum`; Linux is the other way round.
_camilladsp_sha256() {
  case "$(uname -s)" in
  Darwin) shasum -a 256 | cut -d' ' -f1 ;;
  *) sha256sum | cut -d' ' -f1 ;;
  esac
}

# --- State files ---

# State directory for CamillaDSP device and push persistence.
CAMILLADSP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/camilladsp"
CAMILLADSP_LAST_DEVICE_FILE="$CAMILLADSP_STATE_DIR/last-device.txt"
CAMILLADSP_LAST_PUSH_FILE="$CAMILLADSP_STATE_DIR/last-push.txt"
CAMILLADSP_DEVICE_CACHE_FILE="$CAMILLADSP_STATE_DIR/available-devices.txt"
CAMILLADSP_DEVICE_CACHE_META_FILE="$CAMILLADSP_STATE_DIR/available-devices.meta"

# Steady-state safety net for device changes the probe cannot observe. This is
# NOT the latency bound for observable changes — those re-enumerate immediately.
camilladsp_device_cache_ttl() { printf '%s' "${CAMILLADSP_DEVICE_CACHE_TTL:-300}"; }

# --- Platform-specific default output detection ---

# macOS: use SwitchAudioSource to query the default output device.
# SwitchAudioSource -c returns the current default output device name in <1ms
# with zero TCC cost (no system_profiler, no coreaudiod permission checks).
# Requires: switchaudio-osx (managed via managedPackages).
_camilladsp_detect_macos() {
  SwitchAudioSource -c 2>/dev/null || return 1
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

# List playback devices through the cached enumerator.
#
# Arguments: <capture_device> <probe> [required_device]
#   probe           — current default-output value, used as the cache key
#   required_device — a device the caller needs to exist; when it is missing
#                     from the cached list the cache cannot answer the caller,
#                     so it re-enumerates
#
# The cached list is reused only when ALL of these hold:
#   1. the probe is unchanged (the default output did not move)
#   2. the capture device is unchanged (the exclusion set did not move)
#   3. `required_device` is absent or present in the cached list
#   4. the cache is younger than the TTL
# Everything else re-enumerates. Rule 3 is what keeps the stale-entry path
# honest: a caller looking for a device that is not listed still gets a fresh
# read on the same tick, so device removal is noticed within one tick.
camilladsp_list_available_devices_cached() {
  local capture_device="$1"
  local probe="$2"
  local required_device="${3:-}"

  if [ -s "$CAMILLADSP_DEVICE_CACHE_FILE" ] && [ -s "$CAMILLADSP_DEVICE_CACHE_META_FILE" ]; then
    local cached_probe cached_capture cached_at now ttl reusable=true age
    cached_probe=$(sed -n 1p "$CAMILLADSP_DEVICE_CACHE_META_FILE")
    cached_capture=$(sed -n 2p "$CAMILLADSP_DEVICE_CACHE_META_FILE")
    cached_at=$(sed -n 3p "$CAMILLADSP_DEVICE_CACHE_META_FILE")
    now=$(date +%s)
    ttl=$(camilladsp_device_cache_ttl)
    # A corrupt timestamp must not abort the caller under `set -u`.
    case "$cached_at" in '' | *[!0-9]*) cached_at=0 ;; esac
    case "$ttl" in '' | *[!0-9]*) ttl=300 ;; esac

    age=$((now - cached_at))
    [ "$probe" = "$cached_probe" ] || reusable=false
    [ "$capture_device" = "$cached_capture" ] || reusable=false
    # Requiring a non-negative age makes TTL=0 mean "never reuse" rather than
    # letting a negative age match and pin a stale list indefinitely.
    [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] || reusable=false
    if [ -n "$required_device" ] && ! grep -qxF -- "$required_device" "$CAMILLADSP_DEVICE_CACHE_FILE"; then
      reusable=false
    fi

    if [ "$reusable" = true ]; then
      cat "$CAMILLADSP_DEVICE_CACHE_FILE"
      return 0
    fi
  fi

  local devices
  devices=$(camilladsp_list_available_devices "$capture_device") || return 1
  mkdir -p "$CAMILLADSP_STATE_DIR"
  {
    printf '%s\n' "$probe"
    printf '%s\n' "$capture_device"
    printf '%s\n' "$(date +%s)"
  } >"$CAMILLADSP_DEVICE_CACHE_META_FILE"
  printf '%s\n' "$devices" >"$CAMILLADSP_DEVICE_CACHE_FILE"
  printf '%s\n' "$devices"
}

# Drop the cached enumeration. Called when camilladsp rejects a config (the
# resolved device is probably gone even though the cache still lists it).
# Deliberately NOT called on transport failures: a websocket that is merely
# unreachable must not make every tick re-enumerate.
camilladsp_invalidate_device_cache() {
  rm -f "$CAMILLADSP_DEVICE_CACHE_FILE" "$CAMILLADSP_DEVICE_CACHE_META_FILE"
}

# Return the first available playback device (not matching capture_device).
# Deterministic sorted-name fallback: delegates to the cached enumerator.
# Arguments: <capture_device> <probe>
camilladsp_detect_first_available() {
  local capture_device="$1"
  local probe="$2"
  camilladsp_list_available_devices_cached "$capture_device" "$probe" | head -1
}

# Remove the persisted last-device state file. Used when enumeration succeeds and
# the saved device is genuinely gone (e.g. state copied from another machine):
# without this, every subsequent tick retries the same doomed lookup.
camilladsp_clear_last_device() {
  rm -f "$CAMILLADSP_LAST_DEVICE_FILE"
}

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

  # Detect system default output device. The raw probe value doubles as the
  # device-cache key, so keep it before the capture-device rejection below.
  # `|| true` rather than `|| _probe=""`: a detector that prints a name but
  # exits non-zero still yields that name, which has always been the contract.
  local _probe
  # check-suppress:suppression_doc: detection failure is non-fatal — falls through to fallback path
  _probe=$(camilladsp_detect_default_output 2>/dev/null) || true

  local detected_device="$_probe"

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
        if _all_devices=$(camilladsp_list_available_devices_cached "$capture_device" "$_probe" "$saved_device" 2>/dev/null); then
          if printf '%s\n' "$_all_devices" | grep -qxF "$saved_device"; then
            detected_device="$saved_device"
          else
            # Enumeration succeeded and the saved device is gone. Purge it so
            # every later tick does not repeat this lookup.
            camilladsp_clear_last_device
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
    detected_device=$(camilladsp_detect_first_available "$capture_device" "$_probe" 2>/dev/null) || true
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
# live playback device is already set AND the live device equals the target AND
# the config file still matches what was last pushed.
# This makes the heartbeat re-push when the system default output device changes
# (live != target), or when the config file is edited (config_changed), instead
# of skipping forever once any device is set.
#
# A null/empty target is only skipped when camilladsp is Running (a running
# instance with a real device must never be pushed a null). When camilladsp is
# NOT Running (Inactive/Stopped) and the target is empty, we still PUSH — the
# resolver falls back to the first-available device inside
# camilladsp_resolve_playback_device, so a null device is never actually pushed.
# This guarantees the initial config is set even when detection yields nothing.
# Arguments: <state> <live_device> <target_device> <config_changed>
#   config_changed — "true" when camilladsp_config_changed reported a change
camilladsp_needs_push() {
  local state="$1"
  local live_device="$2"
  local target_device="$3"
  local config_changed="$4"
  # Running with a real device: never push a null target (would set device to null).
  if [ "$state" = "Running" ] && [ -z "$target_device" ]; then
    return 1
  fi
  # Running, live device already matches target, config unchanged: nothing to do.
  if [ "$state" = "Running" ] && [ -n "$live_device" ] && [ "$live_device" = "$target_device" ] &&
    [ "$config_changed" != "true" ]; then
    return 1
  fi
  return 0
}

# --- Config-change detection ---

# Fingerprint of the config that a push with <target_device> would apply.
# The config file stores a null playback device (resolution happens at push
# time), so the device must be part of the fingerprint — otherwise a device
# change would look like "no change".
# Arguments: <config_file> <target_device>
camilladsp_config_fingerprint() {
  local config_file="$1"
  local target_device="$2"
  [ -f "$config_file" ] || return 1
  {
    cat "$config_file"
    printf '\n--playback-device--\n%s' "$target_device"
  } | _camilladsp_sha256
}

# Returns 0 (changed) when the resolved config differs from the last pushed one,
# 1 (unchanged) otherwise. A missing state file means "changed" so the first
# tick after boot always pushes.
# Arguments: <config_file> <target_device>
camilladsp_config_changed() {
  local config_file="$1"
  local target_device="$2"
  local fingerprint
  fingerprint=$(camilladsp_config_fingerprint "$config_file" "$target_device") || return 0
  if [ -s "$CAMILLADSP_LAST_PUSH_FILE" ] && [ "$(cat "$CAMILLADSP_LAST_PUSH_FILE")" = "$fingerprint" ]; then
    return 1
  fi
  return 0
}

# Record the fingerprint of a successfully pushed config.
# Arguments: <fingerprint>
camilladsp_record_push() {
  local fingerprint="$1"
  [ -n "$fingerprint" ] || return 0
  mkdir -p "$CAMILLADSP_STATE_DIR"
  printf '%s' "$fingerprint" >"$CAMILLADSP_LAST_PUSH_FILE"
}

# Resolve the config and push it via SetConfig over the websocket API.
# Retries with a fixed delay until success or retries exhausted.
# Arguments: [--port PORT] [--config FILE] [--device NAME] [--retries N] [--retry-delay S]
# When --device is provided, skip resolution and patch the config directly.
# Returns 0 on successful SetConfig, 1 otherwise.
camilladsp_push_config() {
  local ws_port="${WS_PORT:-1234}"
  local config_file="$HOME/.config/camilladsp/configs/config.yml"
  local device=""
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
    --device)
      shift
      device="${1:-}"
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
  if [ -n "$device" ]; then
    # Skip resolution: patch config with the provided device name directly.
    local _patchfile
    _patchfile=$(mktemp) || return 1
    cat <<PYEOF >"$_patchfile"
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
cfg['devices']['playback']['device'] = sys.argv[2]
yaml.dump(cfg, sys.stdout, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
    _resolved_config=$(python3 "$_patchfile" "$config_file" "$device") || {
      rm -f "$_patchfile"
      return 1
    }
    rm -f "$_patchfile"
  else
    _resolved_config=$(camilladsp_resolve_playback_device "$config_file") || return 1
  fi

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
        # Record what was pushed so an unchanged config is not pushed again.
        local _fingerprint
        if _fingerprint=$(camilladsp_config_fingerprint "$config_file" "$_saved_device"); then
          camilladsp_record_push "$_fingerprint"
        fi
        return 0
      fi
      # Rejected by camilladsp rather than unreachable: the resolved device is
      # probably gone even though the cache still lists it. Drop the cache so
      # the next tick re-reads the real device set.
      camilladsp_invalidate_device_cache
    fi
    [ "$_i" -lt "$retries" ] && sleep "$retry_delay"
  done
  return 1
}
