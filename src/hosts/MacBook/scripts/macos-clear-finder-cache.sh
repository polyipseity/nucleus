#!/usr/bin/env bash
# Clear Finder's saved application state cache so desktop visibility settings
# (ShowExternalHardDrivesOnDesktop, ShowHardDrivesOnDesktop,
# ShowMountedServersOnDesktop, ShowRemovableMediaOnDesktop) take effect at once.
# Finder regenerates the cache on next launch from the current defaults.
#
# WHY every apply: Finder serves stale or corrupted cached state and then ignores
# system.defaults, so clearing it keeps the live state matching the declared
# config without a manual cache delete.
#
# Process restarts are handled by Home Manager's relaunchDesktopServices step.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

if _nucleus_resolve_console_user; then
  finder_cache_dir="/Users/$_nucleus_console_user/Library/Saved Application State/com.apple.finder.savedState"
  if [ -d "$finder_cache_dir" ]; then
    if /bin/rm -rf "$finder_cache_dir"; then
      say -l finder "cleared cached application state from $finder_cache_dir"
    else
      # check-suppress:suppression_doc: cache clear is best-effort; missing cache is not a config failure
      warn -l finder "failed to clear cached state at $finder_cache_dir (user may need manual restart)."
    fi
  fi
fi
