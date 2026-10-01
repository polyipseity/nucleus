#!/usr/bin/env bash
# Converge per-app menu-bar and tray icon visibility to the apps.json registry.
#
# WHY set the app-native preference instead of disabling it: icon visibility is
# an AND, so the icon shows only when the app-native setting and the OS both
# allow it. Inverted keys (BetterDisplay hideMenuIcon, Rectangle
# hideMenubarIcon, LuLu noIconMode) come through iconVisibleValue /
# iconHiddenValue, never a disable flag.
#
# Runs as root during darwin-rebuild switch; console-user resolution happens in
# the helper, so headless and SSH sessions degrade gracefully.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

# WHY resolve the root here: apps.json must be readable whether this runs from
# the Nix activation bundle or directly, and derive_repo_root rejects store snapshots.
REPO_ROOT="$(derive_repo_root)" || die -l menu-bar "cannot resolve the nucleus repo root; run nucleus-apply before this activation step."
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

MENU_BAR_CLI="$REPO_ROOT/src/scripts/menu-bar.sh"

if [ ! -f "$MENU_BAR_CLI" ]; then
  warn -l menu-bar "registry CLI not found at $MENU_BAR_CLI; skipping menu-bar icon convergence."
  exit 0
fi

if ! "$MENU_BAR_CLI" apply; then
  die -l menu-bar "one or more app icons failed to converge."
fi
