# shellcheck shell=sh
# Reload macOS user preference state after all managed defaults writes.
# Replaces the reloadUserPreferenceState inline activation block.
#
# Usage: reload-user-preference-state
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
  die "activateSettings -u failed; some preference updates may require relogin."
fi
