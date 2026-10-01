#!/usr/bin/env bash
# Converge GUI app auto-start to the apps.json registry.
#
# WHY the registry CLI: it owns the one uniform mechanism per app (an XDG
# autostart .desktop) after the native auto-start is disabled, so no app-owned
# startup path stays active. The CLI dispatches per user, covering every real
# user's ~/.config/autostart.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# WHY resolve the root here: apps.json must be readable whether this runs from
# the Nix activation bundle or directly, and derive_repo_root rejects store snapshots.
REPO_ROOT="$(derive_repo_root)" || die -l autostart "cannot resolve the nucleus repo root; run nucleus-apply before this activation step."
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

AUTOSTART_CLI="$REPO_ROOT/src/scripts/autostart.sh"

if [ ! -f "$AUTOSTART_CLI" ]; then
  warn -l autostart "registry CLI not found at $AUTOSTART_CLI; skipping app auto-start convergence."
  exit 0
fi

if ! "$AUTOSTART_CLI" apply; then
  die -l autostart "one or more apps failed to converge."
fi
