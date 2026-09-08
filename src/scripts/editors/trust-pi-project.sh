#!/usr/bin/env bash
# Pi project trust injector.
# Inserts trust entries for shared trust paths into ~/.pi/agent/trust.json.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_tpt_python3_bin="$1"

"$_tpt_python3_bin" "$SCRIPT_DIR/trust-pi-project.py"
