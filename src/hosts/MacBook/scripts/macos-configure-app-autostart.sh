#!/usr/bin/env bash
# Converge GUI app auto-start to the apps.json registry on macOS. Runs as root during
# darwin-rebuild switch; console-user resolution happens inside the helper, so headless and SSH
# sessions degrade gracefully.
#
# WHY: this replaces the ad-hoc per-app login-item scripts (MiddleClick, Mounty) and the
# inline steam-autostart disable with one registry-driven mechanism we own. Each app declares
# its desired state in apps.json; we disable its native auto-start (disableNative), then
# enable or disable exactly one uniform mechanism (login item or system extension), so no
# app-owned startup path stays active.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/macos-console-user.sh
. "$SCRIPT_DIR/../../../scripts/lib/macos-console-user.sh"

# WHY: resolve the repo checkout root to read apps.json however this script is invoked (Nix
# activation bundle or direct run). derive_repo_root() takes a live NUCLEUS_REPO_ROOT and
# rejects Nix store snapshots.
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
