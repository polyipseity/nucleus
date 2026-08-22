#!/usr/bin/env bash
# Converge per-app menu-bar / tray icon visibility to the apps.json registry on
# macOS.  WHY: this replaces the ad-hoc per-app defaults keys in defaults.nix and
# the standalone LuLu plist script with a single registry-driven mechanism.
# Every app declares its desired icon state in apps.json; we SET the app's native
# preference to that state (iconVisibleValue / iconHiddenValue) — never disabling
# the native setting, because icon visibility is AND (icon shows only if the
# app-native show setting AND the OS both allow it).  Inverted keys (BetterDisplay
# hideMenuIcon, Rectangle hideMenubarIcon, LuLu noIconMode) are expressed via
# iconVisibleValue / iconHiddenValue, not a disable flag.
#
# Runs as root during darwin-rebuild switch; console-user resolution happens
# inside the helper so it degrades gracefully on headless/SSH sessions.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

# Resolve the repo checkout root so we can read apps.json regardless of how
# this script is invoked (Nix activation bundle vs. direct run).
REPO_ROOT="${NUCLEUS_REPO_ROOT:-$(derive_repo_root)}"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

MENU_BAR_CLI="$REPO_ROOT/src/scripts/menu-bar.sh"

if [ ! -f "$MENU_BAR_CLI" ]; then
  warn -l menu-bar "registry CLI not found at $MENU_BAR_CLI; skipping menu-bar icon convergence."
  exit 0
fi

if ! "$MENU_BAR_CLI" apply; then
  warn -l menu-bar "one or more app icons failed to converge (non-fatal)."
fi
