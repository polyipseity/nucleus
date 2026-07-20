#!/usr/bin/env bash
# Persistent-loop heartbeat for CamillaDSP: pushes the current config if
# camilladsp is not in "Running" state.  Runs indefinitely with exponential
# backoff.  Designed as a persistent daemon (KeepAlive / Restart=always /
# scheduled task AtLogOn) — not a timer-driven oneshot.
#
# Dependencies: websocat, jq (PATH provided via __CAMILLADSP_HEARTBEAT_PATH__ token)
#
# Usage: camilladsp-heartbeat.sh [--port PORT] [--config FILE]
set -euo pipefail

export PATH="__CAMILLADSP_HEARTBEAT_PATH__:$PATH"

# require_command() is provided via require-command-lib.sh (prepended at build time).

# --- Argument parsing ---
ws_port=__CAMILLADSP_WS_PORT__
config_file="$HOME/.config/camilladsp/configs/config.yml"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) shift; ws_port="${1:-$ws_port}" ;;
    --config) shift; config_file="${1:-$config_file}" ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
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

  # --- Skip push if already running ---
  # Avoid filling CamillaDSP's bounded command channel (capacity 10).
  if _state_resp=$(printf '{"GetState":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
    _state=$(printf '%s' "$_state_resp" | jq -r '.GetState.value // empty')
    if [ "$_state" = "Running" ]; then
      _success=true
    fi
  fi

  if [ "$_success" = false ]; then
    # --- Push config ---
    if [ -f "$config_file" ] && _push_resp=$(jq -cRs '{SetConfig: .}' "$config_file" | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null); then
      if printf '%s' "$_push_resp" | jq -e '.SetConfig.result == "Ok"' >/dev/null 2>&1; then
        _success=true
      fi
    fi
  fi

  if [ "$_success" = true ]; then
    _current_sleep=$_base_sleep
  else
    _current_sleep=$((_current_sleep * 2))
    [ "$_current_sleep" -gt "$_max_sleep" ] && _current_sleep=$_max_sleep
  fi

  sleep "$_current_sleep"
done
