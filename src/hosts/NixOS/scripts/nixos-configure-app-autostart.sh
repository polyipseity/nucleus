#!/usr/bin/env bash
# Converge GUI app auto-start to the apps.json registry on NixOS.
# WHY: this replaces the inline nixos-disable-steam-autostart activation script
# with a single registry-driven mechanism we fully own.  Every app declares its
# desired state in apps.json; we disable the app's native auto-start setting
# (disableNative) and then enable/disable exactly one uniform mechanism (an XDG
# autostart .desktop we write/remove) so no app-owned startup path remains
# active.  Runs as root during nixos-rebuild switch and converges every real
# user's ~/.config/autostart via the CLI's per-user dispatch.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# Resolve the repo checkout root so we can read apps.json regardless of how
# this script is invoked (Nix activation bundle vs. direct run).
REPO_ROOT="${NUCLEUS_REPO_ROOT:-$(derive_repo_root)}"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

AUTOSTART_CLI="$REPO_ROOT/scripts/autostart.sh"

if [ ! -f "$AUTOSTART_CLI" ]; then
  warn -l autostart "registry CLI not found at $AUTOSTART_CLI; skipping app auto-start convergence."
  exit 0
fi

if ! "$AUTOSTART_CLI" apply; then
  warn -l autostart "one or more apps failed to converge (non-fatal)."
fi
