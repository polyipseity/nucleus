# Wrapper for applying iCloud exclusions. Sources macos-icloud-exclusions-lib.sh
# and defines _ice_apply which forwards args to apply_exclusions.
#
# Provided functions:
#   _ice_apply JQ_BIN FIND_BIN EXCLUDED_DIRS_JSON MANAGED_ROOTS_JSON
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-icloud-exclusions-lib.sh"

_ice_apply() {
  apply_exclusions "$@"
}
