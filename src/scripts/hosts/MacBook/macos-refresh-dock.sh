#!/usr/bin/env bash
# Restart Dock so declarative Dock defaults take effect immediately.
# Part of nucleus activation sequence; not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"
refresh_dock
