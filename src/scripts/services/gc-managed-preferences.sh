#!/usr/bin/env bash
# Managed macOS preference domain GC.
# Purges stale user preference state for the given domains, then refreshes
# cfprefsd and waits for launchd daemons to settle.
#
# Usage: gc-managed-preferences.sh <space-separated-domains>
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/macos-launch-services.sh
. "$SCRIPT_DIR/../lib/macos-launch-services.sh"

MANAGED_PREF_DOMAINS="${MANAGED_PREF_DOMAINS:-${1:?usage: gc-managed-preferences.sh <space-separated-domains>}}"
export NIX_STORE_BIN="${NIX_STORE_BIN:-nix}"

# shellcheck source=../../platforms/macOS/scripts/macos-gc-preferences.sh
. "$SCRIPT_DIR/../../platforms/macOS/scripts/macos-gc-preferences.sh"

refresh_cfprefsd
wait_for_daemons

echo "Managed preference domains purged. Run your apply flow to re-assert declarative defaults."
