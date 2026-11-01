#!/usr/bin/env bash
# camilladsp-heartbeat.sh - launcher for the resident CamillaDSP heartbeat.
#
# The daemon lives in camilladsp-heartbeat.py next to this file. Keeping the
# shell entry point preserves scriptName, the bundle layout and
# writeNucleusShellApplication; the exec happens once, so a tick spawns nothing.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
exec python3 "$SCRIPT_DIR/camilladsp-heartbeat.py" "$@"
