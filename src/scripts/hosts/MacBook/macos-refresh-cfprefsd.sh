#!/usr/bin/env bash
# Kill cfprefsd so preference changes are re-read from plist files,
# then wait for killed daemons to flush and restart.
# Part of nucleus activation sequence; not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"
refresh_cfprefsd
wait_for_daemons
