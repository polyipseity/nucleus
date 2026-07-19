#!/usr/bin/env bash
# Flush daemon caches so services menu changes take effect.
# cfprefsd caches preference plists; pbs caches the services menu.
# Part of nucleus activation sequence; not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services-lib.sh"
refresh_services_menu
