# Unprotect opencode agents/commands symlinks before linkGeneration.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"
_nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/agents"
_nucleus_unprotect_symlink "agents.nix" "$HOME/.config/opencode/commands"
