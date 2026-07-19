# Source this file in activation blocks that need to (un)protect managed paths
# (out-of-store symlinks).  Defines _nmp_unprotect and _nmp_protect that
# forward args to _nucleus_{unprotect,protect}_managed_paths.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/./symlink-hardening-lib.sh"
. "$SCRIPT_DIR/./manage-out-of-store-symlinks.sh"

_nmp_unprotect() {
  _nucleus_unprotect_managed_paths "$@"
}

_nmp_protect() {
  _nucleus_protect_managed_paths "$@"
}
