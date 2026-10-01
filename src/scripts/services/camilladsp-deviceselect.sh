#!/usr/bin/env bash
# Device detection and config-push library for CamillaDSP playback device selection,
# sourced by camilladsp-run.sh and camilladsp-heartbeat.sh. Needs python3 (yaml),
# websocat, jq, SwitchAudioSource (macOS), shasum/sha256sum and wpctl/pactl/aplay
# (Linux).
#
# Detection order for a null devices.playback.device: system default output, last saved
# default validated against the available devices, first available in sorted-name order.
# The capture device is never selected, since playback and capture on one device is an
# audio loop.
#
# The raw enumerator is expensive on macOS (system_profiler, coreaudiod and TCC work),
# so anything inside a polling loop uses the cached wrapper, which re-enumerates the
# moment the probe, capture device, TTL or a required device says the cache cannot
# answer.
set -euo pipefail

_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$_LIB_DIR/../lib/lib.sh"
. "$_LIB_DIR/../lib/require-command.sh"
unset _LIB_DIR

# Named to be recognized by the step 17 awk parser's local_funcs tracking.
_has_command() { command -v "$1" >/dev/null 2>&1; }

_camilladsp_sha256() {
  case "$(uname -s)" in
  Darwin) shasum -a 256 | cut -d' ' -f1 ;;
  *) sha256sum | cut -d' ' -f1 ;;
  esac
}

CAMILLADSP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/camilladsp"
CAMILLADSP_LAST_DEVICE_FILE="$CAMILLADSP_STATE_DIR/last-device.txt"
CAMILLADSP_LAST_PUSH_FILE="$CAMILLADSP_STATE_DIR/last-push.txt"
CAMILLADSP_DEVICE_CACHE_FILE="$CAMILLADSP_STATE_DIR/available-devices.txt"
CAMILLADSP_DEVICE_CACHE_META_FILE="$CAMILLADSP_STATE_DIR/available-devices.meta"

# Safety net for device changes the probe cannot observe, not the latency bound for observable changes, which re-enumerate immediately.
camilladsp_device_cache_ttl() { printf '%s' "${CAMILLADSP_DEVICE_CACHE_TTL:-300}"; }

# macOS: SwitchAudioSource -c answers the default output name in <1ms with no TCC cost, unlike system_profiler. Needs switchaudio-osx from managedPackages.
_camilladsp_detect_macos() {
  SwitchAudioSource -c 2>/dev/null || return 1
}

# Linux: try WirePlumber → PulseAudio → ALSA in order.
_camilladsp_detect_linux() {
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

# macOS: enumerate output-capable devices (presence of coreaudio_device_output), excluding the capture device. Device flags are flat top-level keys on real system_profiler output.
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
  # WHY: pin collation so the ordering does not depend on the caller's locale.
  printf '%s\n' "${names[@]}" | LC_ALL=C sort
}

_camilladsp_list_available_linux() {
  local capture_device="$1"
  local -a candidates=()

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

  if _has_command pactl; then
    local sink
    while IFS= read -r sink; do
      [ -n "$sink" ] && [ "$sink" != "$capture_device" ] && candidates+=("$sink")
    done < <(pactl list sinks short 2>/dev/null |
      awk '{print $2}')
  fi

  if _has_command aplay; then
    local card
    while IFS= read -r card; do
      [ -n "$card" ] && candidates+=("hw:CARD=${card},DEV=0")
    done < <(aplay -l 2>/dev/null |
      grep '^card [0-9]' |
      sed 's/card \([0-9]*\): .*/\1/')
  fi

  [ "${#candidates[@]}" -eq 0 ] && return 1
  # WHY: same locale pin as the macOS enumerator.
  printf '%s\n' "${candidates[@]}" | LC_ALL=C sort
}

camilladsp_list_available_devices() {
  local capture_device="$1"
  case "$(uname -s)" in
  Darwin) _camilladsp_list_available_macos "$capture_device" ;;
  Linux) _camilladsp_list_available_linux "$capture_device" ;;
  *) return 1 ;;
  esac
}

# Reuse the cached list only when the probe and capture device are unchanged, required_device is absent or listed, and the cache is younger than the TTL. Requiring a device the caller needs is what keeps the stale-entry path honest: a caller looking for an unlisted device gets a fresh read on the same tick, so device removal is noticed within one tick.
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

# Called when camilladsp rejects a config, since the resolved device is probably gone even though the cache still lists it. Deliberately not called on transport failures: an unreachable websocket must not make every tick re-enumerate.
camilladsp_invalidate_device_cache() {
  rm -f "$CAMILLADSP_DEVICE_CACHE_FILE" "$CAMILLADSP_DEVICE_CACHE_META_FILE"
}

camilladsp_detect_first_available() {
  local capture_device="$1"
  local probe="$2"
  camilladsp_list_available_devices_cached "$capture_device" "$probe" | head -1
}

# Used when enumeration succeeds and the saved device is genuinely gone (state copied from another machine): without this every later tick retries the same doomed lookup.
camilladsp_clear_last_device() {
  rm -f "$CAMILLADSP_LAST_DEVICE_FILE"
}

camilladsp_save_last_device() {
  local device="$1"
  [ -n "$device" ] || return 0
  mkdir -p "$CAMILLADSP_STATE_DIR"
  printf '%s' "$device" >"$CAMILLADSP_LAST_DEVICE_FILE"
}

camilladsp_load_last_device() {
  if [ -s "$CAMILLADSP_LAST_DEVICE_FILE" ]; then
    cat "$CAMILLADSP_LAST_DEVICE_FILE"
    return 0
  fi
  return 1
}

camilladsp_resolve_playback_device() {
  local config_file="$1"

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

  if [ -n "$playback_device" ]; then
    cat "$config_file"
    return 0
  fi

  # WHY: the raw probe value doubles as the device-cache key, so keep it before the capture-device rejection below. `|| true` rather than `|| _probe=""`, because a detector that prints a name but exits non-zero still yields that name.
  local _probe
  # check-suppress:suppression_doc: detection failure is non-fatal — falls through to fallback path
  _probe=$(camilladsp_detect_default_output 2>/dev/null) || true

  local detected_device="$_probe"

  # Hard invariant: the capture device must never become playback, which would create an audio loop (output to capture to processed output).
  if [ -n "$detected_device" ] && [ "$detected_device" = "$capture_device" ]; then
    detected_device=""
  fi

  if [ -z "$detected_device" ]; then
    local saved_device
    if saved_device=$(camilladsp_load_last_device 2>/dev/null); then
      if [ -n "$saved_device" ] && [ "$saved_device" != "$capture_device" ]; then
        local _all_devices
        if _all_devices=$(camilladsp_list_available_devices_cached "$capture_device" "$_probe" "$saved_device" 2>/dev/null); then
          if printf '%s\n' "$_all_devices" | grep -qxF "$saved_device"; then
            detected_device="$saved_device"
          else
            # Enumeration succeeded and the saved device is gone, so purge it.
            camilladsp_clear_last_device
          fi
        else
          # Enumeration failed: accept the saved device as best effort.
          detected_device="$saved_device"
        fi
      fi
    fi
  fi

  if [ -z "$detected_device" ]; then
    # check-suppress:suppression_doc: detection failure is non-fatal — passes through with empty device
    detected_device=$(camilladsp_detect_first_available "$capture_device" "$_probe" 2>/dev/null) || true
  fi

  if [ -z "$detected_device" ]; then
    cat "$config_file"
    return 0
  fi

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

# The device detection would currently select, or empty when it yields nothing.
# The heartbeat uses it to see whether the live device drifted from the desired one.
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

# Pure skip decision. Returns 1 (skip) only when camilladsp is Running, the live device equals the target, and the config still matches the last push, so the heartbeat re-pushes on a changed default output or an edited config.
# A null target is skipped only while Running; a stopped instance is still pushed, because the resolver falls back to the first available device and a null device is never actually pushed.
camilladsp_needs_push() {
  local state="$1"
  local live_device="$2"
  local target_device="$3"
  local config_changed="$4"
  # Running with a real device: never push a null target.
  if [ "$state" = "Running" ] && [ -z "$target_device" ]; then
    return 1
  fi
  if [ "$state" = "Running" ] && [ -n "$live_device" ] && [ "$live_device" = "$target_device" ] &&
    [ "$config_changed" != "true" ]; then
    return 1
  fi
  return 0
}

# WHY: the config stores a null playback device, so the device must be part of the fingerprint; otherwise a device change would look like no change.
camilladsp_config_fingerprint() {
  local config_file="$1"
  local target_device="$2"
  [ -f "$config_file" ] || return 1
  {
    cat "$config_file"
    printf '\n--playback-device--\n%s' "$target_device"
  } | _camilladsp_sha256
}

# A missing state file means changed, so the first tick after boot always pushes.
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

camilladsp_record_push() {
  local fingerprint="$1"
  [ -n "$fingerprint" ] || return 0
  mkdir -p "$CAMILLADSP_STATE_DIR"
  printf '%s' "$fingerprint" >"$CAMILLADSP_LAST_PUSH_FILE"
}

# Resolve the config and push it via SetConfig over the websocket API, retrying with a fixed delay. --device skips resolution and patches the config directly.
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
        local _saved_device
        _saved_device=$(printf '%s' "$_resolved_config" | python3 -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin.read())
d = cfg.get('devices', {}).get('playback', {}).get('device', None)
print(d if d is not None else '')
" 2>/dev/null) || true # check-suppress:suppression_doc: YAML parsing is best-effort; missing device field is handled by downstream fallback
        [ -n "$_saved_device" ] && camilladsp_save_last_device "$_saved_device"
        local _fingerprint
        if _fingerprint=$(camilladsp_config_fingerprint "$config_file" "$_saved_device"); then
          camilladsp_record_push "$_fingerprint"
        fi
        return 0
      fi
      # Rejected by camilladsp rather than unreachable, so the resolved device is probably gone even though the cache still lists it.
      camilladsp_invalidate_device_cache
    fi
    [ "$_i" -lt "$retries" ] && sleep "$retry_delay"
  done
  return 1
}
