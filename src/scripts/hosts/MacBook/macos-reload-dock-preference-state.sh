#!/usr/bin/env bash
# Reload Dock preference state.
# Replaces the macos-reload-dock inline activation block.
#
# Usage: reload-dock-preference-state
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services.sh"

refresh_dock
