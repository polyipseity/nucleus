#!/usr/bin/env bash
# Persistent-loop heartbeat for CamillaDSP: pushes the current config unless
# camilladsp is Running AND the live playback device is already set (idiot-proof
# skip: a null live device is always corrected).  Runs indefinitely with
# exponential backoff.  Designed as a persistent daemon (KeepAlive /
# Restart=always / scheduled task AtLogOn) — not a timer-driven oneshot.
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
  # --- Runtime toggle from config.json ---
  # Respects the camilladsp.heartbeat flag for dynamic disable.
  config_json="$HOME/.local/state/nucleus/config.json"
  if [ -f "$config_json" ]; then
    _hb_enabled=$(jq -r '.camilladsp.heartbeat // true' "$config_json")
    if [ "$_hb_enabled" = "false" ]; then
      sleep "$_base_sleep"
      continue
    fi
  fi

  _success=false

  # --- Decide whether a push is needed ---
  # Query live state and the live playback device. If the websocket is
  # unreachable, leave both empty (treated as "push"). The skip decision is
  # idiot-proof: skip ONLY when Running AND the live device is already set. A
  # null live device can never be skipped, so a null device is always corrected.
  _state=""
  _live=""
  if _state_resp=$(printf '{"GetState":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
    _state=$(printf '%s' "$_state_resp" | jq -r '.GetState.value // empty')
  fi
  if _config_resp=$(printf '{"GetConfig":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
    _live=$(printf '%s' "$_config_resp" | jq -r '.GetConfig.value.devices.playback.device // empty')
  fi

  if camilladsp_needs_push "$_state" "$_live"; then
    # --- Push config ---
    # Resolve playback device: patches empty device in config with system default.
    if camilladsp_push_config --port "$ws_port" --config "$config_file"; then
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
