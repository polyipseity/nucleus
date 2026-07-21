# VS Code workspace trust injector.
# Inserts a workspace trust entry for ~/dev into VS Code's SQLite state DB.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_twt_python3_bin="$1"

"$_twt_python3_bin" "$SCRIPT_DIR/trust-vscode-workspace.py"
