# Source this file (via builtins.readFile in Nix activation) to make
# symlink-hardening functions (_nucleus_{protect,unprotect}_symlink, etc.)
# available in activation blocks.
# Not intended for standalone use.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/./symlink-hardening-lib.sh"
