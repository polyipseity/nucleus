#!/usr/bin/env bash
# iCloud exclusion convergence for the daily launchd agent.
# Forwards all positional args to apply_exclusions (defined in the shared lib).
# See macos-icloud-exclusions.sh for the full function doc.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/macos-icloud-exclusions.sh
. "$SCRIPT_DIR/../lib/macos-icloud-exclusions.sh"

apply_exclusions "$@"
