#!/usr/bin/env bash
# Converge per-app menu-bar / tray icon visibility to the apps.json registry on
# NixOS.  WHY: this mirrors the macOS icon-convergence mechanism — every app
# declares its desired icon state in apps.json, and we SET the app's native
# preference to that state (iconVisibleValue / iconHiddenValue).  Icon
# visibility is AND (icon shows only if the app-native show setting AND the OS
# both allow it), so the native setting is SET, never disabled.  Runs as root
# during nixos-rebuild switch and converges every real user via the CLI's
# per-user dispatch.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

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
