#!/usr/bin/env bash
# Process runner for CamillaDSP. Starts camilladsp with --no_config and
# supervises the single process until it exits. Config is pushed by the
# separate camilladsp-heartbeat service — this script does NOT push config.
#
# Dependencies: camilladsp — PATH managed via writeShellApplication runtimeInputs
#
# Usage: camilladsp-run.sh [--port PORT] [--statefile PATH] [--logfile FILE]
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
. "$SCRIPT_DIR/../lib/require-command.sh"

# --- Argument parsing ---
ws_port="${WS_PORT:-1234}"
state_file="$HOME/.local/state/camilladsp/statefile.yml"
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

mkdir -p "$(dirname "$state_file")" "$(dirname "$log_file")"

require_command camilladsp

# Start camilladsp in background and supervise the single process until it exits.
camilladsp -p "$ws_port" --statefile "$state_file" -w --no_config -o "$log_file" &
pid=$!

# Wait for camilladsp to exit
wait "$pid"
