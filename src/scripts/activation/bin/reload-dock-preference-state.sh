# shellcheck shell=sh
# Reload Dock preference state.
# Replaces the reloadDockPreferenceState inline activation block.
#
# Usage: reload-dock-preference-state
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/macos-launch-services-lib.sh"

refresh_dock
