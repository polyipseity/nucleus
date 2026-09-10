#!/usr/bin/env bash
# Persistent-loop heartbeat for CamillaDSP: the ONLY component that pushes the
# config. It pushes when camilladsp is not Running, when the live playback device
# has drifted from the device detection would select, or when the config file has
# changed since the last push (camilladsp_config_changed). Runs indefinitely with
# exponential backoff.  Designed as a persistent daemon (KeepAlive /
# Restart=always / scheduled task AtLogOn) — not a timer-driven oneshot.
#
# Automatic binding is controlled by the camilladsp.enable toggle (default
# true).  Binding holds an open capture device, and the OS privacy-indicator
# path for that is broken on this hardware, so the toggle exists to stop the
# loop binding without stopping the loop itself.
#
# Dependencies: websocat, jq, python3 (yaml) — PATH managed via writeShellApplication runtimeInputs
#
# Usage: camilladsp-heartbeat.sh [--port PORT] [--config FILE]
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/require-command.sh"
# shellcheck source=camilladsp-deviceselect.sh
. "$SCRIPT_DIR/camilladsp-deviceselect.sh"

# --- Argument parsing ---
ws_port="${WS_PORT:-1234}"
config_file="$HOME/.config/camilladsp/configs/config.yml"

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
  *)
    error "unknown argument: $1"
    exit 1
    ;;
  esac
  shift
done

require_command websocat
require_command jq

# --- Exponential backoff ---
# Base delay 5 s, cap at 300 s.  Reset on success, double on failure.
_base_sleep=5
_max_sleep=300
_current_sleep=$_base_sleep

# --- Main loop (persistent daemon pattern) ---
while true; do
  # --- Runtime toggles from config.json ---
  # camilladsp.heartbeat — master switch for this loop (default true).
  # camilladsp.enable    — gates automatic device binding (default true).
  #   With binding off the loop still runs, so the service stays loaded and the
  #   websocket API stays up for camillagui, but nothing opens an audio input.
  #   WHY: an open capture device lights the macOS microphone privacy indicator,
  #   and the indicator path is broken on this board (J813), which burns ~40% of
  #   a core in WindowServer — set this false to stop that.  A manual push from
  #   camillagui still applies normally either way.
  config_json="$(case "$(uname -s)" in Darwin) echo "$HOME/Library/Application Support/nucleus/config.json" ;; *) echo "$HOME/.local/share/nucleus/config.json" ;; esac)"
  _hb_enabled=true
  _bind_enabled=true
  if [ -f "$config_json" ]; then
    # `//` cannot be used for these: jq treats `false` as empty, so `.key // true`
    # yields true for an explicit false and the toggle could never be disabled.
    _hb_enabled=$(jq -r 'if .camilladsp.heartbeat == null then true else .camilladsp.heartbeat end' "$config_json")
    _bind_enabled=$(jq -r 'if .camilladsp.enable == null then true else .camilladsp.enable end' "$config_json")
  fi
  # With binding disabled there is nothing to probe for — the probe exists only
  # to feed the push decision — so the whole tick is skipped rather than doing
  # cheap work that can never have an effect.
  if [ "$_hb_enabled" = "false" ] || [ "$_bind_enabled" != "true" ]; then
    sleep "$_base_sleep"
    continue
  fi

  _success=false

  # --- Decide whether a push is needed ---
  # Query live state and the live playback device. If the websocket is
  # unreachable, leave both empty (treated as "push"). The skip decision
  # compares the live device against the target device that detection would
  # currently select: skip ONLY when Running AND the live device is already set
  # AND it equals the target AND the config file is unchanged. When the system
  # default output device changes, or the config file is edited, the decision
  # pushes instead of skipping forever. A null target is never pushed (it would
  # set the device to null).
  _state=""
  _live=""
  if _state_resp=$(printf '{"GetState":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
    _state=$(printf '%s' "$_state_resp" | jq -r '.GetState.value // empty')
  fi
  # GetConfig.value is a YAML string, not JSON — extract the live playback
  # device via python yaml so the skip decision sees the real device.
  if _config_resp=$(printf '{"GetConfig":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
    _live=$(printf '%s' "$_config_resp" | python3 -c "
import sys, json, yaml
try:
    v = json.load(sys.stdin)['GetConfig']['value']
    print(yaml.safe_load(v).get('devices', {}).get('playback', {}).get('device', '') or '')
except Exception:
    pass
")
  fi

  # Target device that detection would currently select (empty if none).
  _target=""
  if [ -f "$config_file" ]; then
    # check-suppress:suppression_doc: detection failure is non-fatal — empty target is treated as "skip" by the push decision
    _target=$(camilladsp_target_playback_device "$config_file" 2>/dev/null) || true
  fi

  # Did the config on disk change since the last push? Compared against what we
  # last pushed, so edits made through camillagui are never reverted here.
  _changed=false
  if [ -f "$config_file" ] && camilladsp_config_changed "$config_file" "$_target"; then
    _changed=true
  fi

  if camilladsp_needs_push "$_state" "$_live" "$_target" "$_changed"; then
    # --- Push config ---
    # Pass resolved device to avoid redundant detection on push.
    if camilladsp_push_config --port "$ws_port" --config "$config_file" --device "$_target"; then
      _success=true
    fi
  else
    # Already converged (Running with a live device set) — nothing to do.
    _success=true
  fi

  if [ "$_success" = true ]; then
    _current_sleep=$_base_sleep
  else
    _current_sleep=$((_current_sleep * 2))
    [ "$_current_sleep" -gt "$_max_sleep" ] && _current_sleep=$_max_sleep
  fi

  sleep "$_current_sleep"
done
