#!/usr/bin/env bash
# Pi project trust injector.
# Inserts trust entries for shared trust paths into ~/.pi/agent/trust.json.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 trust-pi-project

_tpt_python3_bin="$1"

"$_tpt_python3_bin" "$SCRIPT_DIR/trust-pi-project.py"
