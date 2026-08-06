#!/usr/bin/env bash
# Shared daemon wrapper for CamillaDSP.
# Starts camilladsp with --no_config, pushes the initial config via websocket,
# then blocks until camilladsp exits.  The heartbeat is a separate service.
#
# Dependencies: camilladsp, websocat, jq (PATH managed via writeShellApplication runtimeInputs)
#
# Usage: camilladsp-daemon.sh [--port PORT] [--statefile PATH] [--config FILE] [--logfile FILE]
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/require-command.sh"

# --- Argument parsing ---
ws_port="${WS_PORT:-1234}"
state_file="$HOME/.local/state/camilladsp/statefile.yml"
config_file="$HOME/.config/camilladsp/configs/config.yml"
log_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --port) shift; ws_port="${1:-$ws_port}" ;;
    --statefile) shift; state_file="${1:-$state_file}" ;;
    --config) shift; config_file="${1:-$config_file}" ;;
    --logfile) shift; log_file="${1:-}" ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# Auto-detect log file when not specified
if [ -z "$log_file" ]; then
  log_file="$(nucleus_log_dir)/camilladsp/camilladsp.log"
fi

require_command camilladsp
require_command websocat
require_command jq

mkdir -p "$(dirname "$state_file")" "$(dirname "$log_file")"

# Start camilladsp in background — it must be running before we can push
# the initial config via websocket.
camilladsp -p "$ws_port" --statefile "$state_file" -w --no_config -o "$log_file" &
pid=$!

# Push initial config (retry up to ~30 s)
if [ -f "$config_file" ]; then
  for _i in $(seq 1 60); do
    if jq -cRs '{SetConfig: .}' "$config_file" | \
       websocat -1 "ws://127.0.0.1:$ws_port" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
fi

# Wait for camilladsp to exit
wait "$pid"
