#!/usr/bin/env bash
# Process supervisor for CamillaDSP.
# Starts camilladsp with --no_config, pushes the initial config once via the
# shared deviceselect lib, then blocks until camilladsp exits.  The heartbeat
# (camilladsp-heartbeat.sh) is a separate service that keeps the config
# converged.  This script does NOT loop — it supervises a single process.
#
# Dependencies: camilladsp, websocat, jq, python3 (yaml) — PATH managed via writeShellApplication runtimeInputs
#
# Usage: camilladsp-supervisor.sh [--port PORT] [--statefile PATH] [--config FILE] [--logfile FILE]
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/require-command.sh"
# shellcheck source=camilladsp-deviceselect.sh
. "$SCRIPT_DIR/camilladsp-deviceselect.sh"

# --- Argument parsing ---
ws_port="${WS_PORT:-1234}"
state_file="$HOME/.local/state/camilladsp/statefile.yml"
config_file="$HOME/.config/camilladsp/configs/config.yml"
log_file=""

while [ $# -gt 0 ]; do
  case "$1" in
  --port)
    shift
    ws_port="${1:-$ws_port}"
    ;;
  --statefile)
    shift
    state_file="${1:-$state_file}"
    ;;
  --config)
    shift
    config_file="${1:-$config_file}"
    ;;
  --logfile)
    shift
    log_file="${1:-}"
    ;;
  *)
    error "unknown argument: $1"
    exit 1
    ;;
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

# Push initial config once (retry up to ~30 s).  The shared lib resolves the
# playback device and pushes via websocket.
if [ -f "$config_file" ]; then
  camilladsp_push_config --port "$ws_port" --config "$config_file" --retries 60 --retry-delay 0.5
fi

# Wait for camilladsp to exit
wait "$pid"
