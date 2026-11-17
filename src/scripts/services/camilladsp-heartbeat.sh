#!/usr/bin/env bash
# camilladsp-heartbeat.sh - launcher for the resident CamillaDSP heartbeat.
#
# The daemon lives in camilladsp-heartbeat.py next to this file. Keeping the
# shell entry point preserves scriptName, the bundle layout and
# writeNucleusShellApplication; the exec happens once, so a tick spawns nothing.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 camilladsp-heartbeat
exec python3 "$SCRIPT_DIR/camilladsp-heartbeat.py" "$@"
