#!/usr/bin/env bash
# Refresh TISwitcher so input-source changes take effect.
# Part of nucleus activation sequence; not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"
refresh_tiswitcher
