# Source this file in activation blocks that need to protect a symlink via
# env vars.  The caller MUST set NPS_SOURCE_NAME and NPS_TARGET_PATH before
# sourcing this file.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/./symlink-hardening-lib.sh"
_nucleus_protect_symlink "${NPS_SOURCE_NAME:?}" "${NPS_TARGET_PATH:?}"
