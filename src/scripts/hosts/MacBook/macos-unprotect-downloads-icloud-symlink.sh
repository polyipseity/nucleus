# Unprotect the ~/Downloads/iCloud symlink before linkGeneration.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/symlink-hardening-lib.sh"
_nucleus_unprotect_symlink "macos.nix" "$HOME/Downloads/iCloud"
