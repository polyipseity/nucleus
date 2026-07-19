#!/usr/bin/env bash
# Restart desktop system processes after configuration changes.
# Uses launchctl kickstart for Finder (preserves window state) and
# killall for SystemUIServer/WindowManager (no launchd service).
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"
refresh_desktop_services
