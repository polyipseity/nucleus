# Self-executing application of iCloud exclusions.
# Sources macos-icloud-exclusions-lib.sh and calls apply_exclusions
# with token placeholders substituted at Nix eval time.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
. "$SCRIPT_DIR/../../lib/macos-icloud-exclusions-lib.sh"

apply_exclusions '__JQ_BIN__' '__FIND_BIN__' '__EXCLUDED_DIRS_JSON__' '__MANAGED_ROOTS_JSON__'
