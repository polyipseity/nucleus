# Source this file in activation blocks that need to unprotect a symlink via
# env vars.  The caller MUST set NUS_SOURCE_NAME and NUS_TARGET_PATH before
# sourcing this file.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/./symlink-hardening-lib.sh"
_nucleus_unprotect_symlink '__NAME__' '__TARGET_PATH__'
