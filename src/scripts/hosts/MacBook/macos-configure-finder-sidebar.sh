# Wrapper for configuring Finder sidebar favorites. Sources macos-finder-sidebar.sh
# and defines _cfs_configure which forwards args to finder_configure_sidebar.
#
# Provided functions:
#   _cfs_configure FAVORITES_JSON JQ_BIN MYSIDES_BIN EXPECTED_ORDER MANAGED_COUNT
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar.sh"

_cfs_configure() {
  finder_configure_sidebar "$1" "$2" "$3" "$4" "$5"
}
