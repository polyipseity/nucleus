# Reload macOS user preference state after all managed defaults writes.
# Without this, cfprefsd and related daemons hold stale values in memory
# until logout/login.
set -eu
if ! /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
  echo "macos: activateSettings -u failed; some preference updates may require relogin." >&2
fi
