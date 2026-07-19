# Source this file (via builtins.readFile in Nix activation) to make
# manage-out-of-store-symlinks functions available in activation blocks.
# Not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/./manage-out-of-store-symlinks.sh"
