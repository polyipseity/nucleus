# Protect the ~/Downloads/iCloud symlink after linkGeneration.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/symlink-hardening-lib.sh"
_nucleus_protect_symlink "macos.nix" "$HOME/Downloads/iCloud"
