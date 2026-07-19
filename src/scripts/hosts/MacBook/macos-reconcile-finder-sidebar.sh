# Self-executing reconciliation of Finder sidebar favorites after daemon restart.
# Sources macos-finder-sidebar.sh and calls finder_reconcile_best_effort
# with token placeholders substituted at Nix eval time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar.sh"

_mysides_bin="__MYSIDES_BIN__"
if [ -x "$_mysides_bin" ]; then
  finder_reconcile_best_effort '__FAVORITES_JSON__' '__JQ_BIN__' "$_mysides_bin"
fi
