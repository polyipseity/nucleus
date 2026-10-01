#!/usr/bin/env bash
# Converge per-app menu-bar and tray icon visibility to the apps.json registry on NixOS. Runs
# as root during nixos-rebuild switch and converges every real user via the CLI's per-user
# dispatch.
#
# WHY: this mirrors the macOS icon-convergence mechanism. Each app declares its desired icon
# state in apps.json, and we set the app's native preference to that state (iconVisibleValue /
# iconHiddenValue). Icon visibility is an AND of the app-native setting and the OS, so the
# native setting is set, never disabled.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# WHY: resolve the repo checkout root to read apps.json however this script is invoked (Nix
# activation bundle or direct run). derive_repo_root() takes a live NUCLEUS_REPO_ROOT and
# rejects Nix store snapshots.
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
