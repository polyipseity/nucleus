# shellcheck shell=sh
# Reload macOS user preference state after all managed defaults writes.
# Replaces the reloadUserPreferenceState inline activation block.
#
# Usage: reload-user-preference-state
set -eu

if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
  echo "reload-user-preference-state: activateSettings -u failed; some preference updates may require relogin." >&2
fi
