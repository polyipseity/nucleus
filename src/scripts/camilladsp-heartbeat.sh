#!/usr/bin/env bash
# Heartbeat for CamillaDSP: pushes the current config if camilladsp is
# not in "Running" state.  Designed to be invoked periodically by a
# timer (launchd StartInterval, systemd OnUnitActiveSec).
#
# Dependencies (must be in PATH): websocat, jq
#
# Usage: camilladsp-heartbeat.sh [--port PORT] [--config FILE]
set -euo pipefail

# --- Self-contained helpers ---
require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}
# -------------------------------------------------------------------

# --- Argument parsing ---
ws_port=1234
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

# --- Runtime toggle from config.json ---
# Respects the camilladsp.heartbeat flag for dynamic disable.
config_json="$HOME/.local/state/nucleus/config.json"
if [ -f "$config_json" ]; then
  _hb_enabled=$(jq -r '.camilladsp.heartbeat // true' "$config_json")
  [ "$_hb_enabled" = "false" ] && exit 0
fi

# --- Skip push if already running ---
# Avoid filling CamillaDSP's bounded command channel (capacity 10).
# undoc-supp: CamillaDSP WS may not be reachable yet; heartbeat loop handles this.
_state_resp=$(printf '{"GetState":null}' | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null) || true
_state=$(printf '%s' "$_state_resp" | jq -r '.GetState.value // empty')
[ "$_state" = "Running" ] && exit 0

# --- Push config ---
[ -f "$config_file" ] || exit 0
# undoc-supp: CamillaDSP WS may not be reachable yet; heartbeat loop handles this.
_push_resp=$(jq -cRs '{SetConfig: .}' "$config_file" | websocat -1 "ws://127.0.0.1:$ws_port" 2>/dev/null) || true
# undoc-supp: CamillaDSP WS response may not be Ok yet; heartbeat loop handles this.
printf '%s' "$_push_resp" | jq -e '.SetConfig.result == "Ok"' >/dev/null 2>&1 || true
