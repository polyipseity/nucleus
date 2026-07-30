#!/usr/bin/env bash
# Restart desktop services (Finder + SystemUIServer + WindowManager) and
# reconcile sidebar favorites after restart.
# Replaces the relaunchDesktopServices inline activation block.
#
# Usage: relaunch-desktop-services <favorites-json> <jq-bin> <mysides-bin>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-launch-services.sh"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar.sh"

_favorites_json="$1"
_jq_bin="$2"
_mysides_bin="$3"

refresh_desktop_services

if [ -x "$_mysides_bin" ]; then
  finder_reconcile_best_effort "$_favorites_json" "$_jq_bin" "$_mysides_bin"
fi
