# Protect opencode agents/commands symlinks after linkGeneration.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/symlink-hardening-lib.sh"
_nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/agents"
_nucleus_protect_symlink "agents.nix" "$HOME/.config/opencode/commands"
