#!/usr/bin/env bash
# Converge exactly one BetterDisplay virtual screen (HeadlessDisplay) and keep
# it connected for clamshell remote-desktop fallback. No-op if BetterDisplay is
# not installed.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/betterdisplay.sh
. "$SCRIPT_DIR/../../../scripts/lib/betterdisplay.sh"

bd_reconcile || die "failed to converge BetterDisplay virtual screen '${BD_DISPLAY_NAME}' (observed: ${BD_RECONCILE_OBSERVED-})"
