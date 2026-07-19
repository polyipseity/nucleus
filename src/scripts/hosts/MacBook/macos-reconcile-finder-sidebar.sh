# Wrapper for reconciling Finder sidebar favorites after daemon restart.
# Sources macos-finder-sidebar.sh and defines _rec_reconcile which forwards
# args to finder_reconcile_best_effort.
#
# Provided functions:
#   _rec_reconcile FAVORITES_JSON JQ_BIN MYSIDES_BIN
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar.sh"

_rec_reconcile() {
  finder_reconcile_best_effort "$1" "$2" "$3"
}
