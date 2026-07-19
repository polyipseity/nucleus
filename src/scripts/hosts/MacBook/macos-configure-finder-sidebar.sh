# Self-executing configuration of Finder sidebar favorites.
# Sources macos-finder-sidebar.sh and calls finder_configure_sidebar
# with token placeholders substituted at Nix eval time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-finder-sidebar.sh"

finder_configure_sidebar '__FAVORITES_JSON__' '__JQ_BIN__' '__MYSIDES_BIN__' '__EXPECTED_ORDER__' '__MANAGED_COUNT__'
