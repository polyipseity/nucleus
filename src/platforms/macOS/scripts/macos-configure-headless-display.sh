#!/usr/bin/env bash
# Converge one BetterDisplay virtual screen (HeadlessDisplay).
# No-op if BetterDisplay is not installed.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"
# shellcheck source=../../../scripts/lib/betterdisplay.sh
. "$SCRIPT_DIR/../../../scripts/lib/betterdisplay.sh"

if [ ! -x "$BD_BIN" ]; then
  exit 0
fi

if ! bd_app_running; then
  die "BetterDisplay is not running; cannot configure headless display"
fi

bd_probe

tag_count="$(bd_tag_ids_for_name | /usr/bin/awk 'NF { n++ } END { print n + 0 }')"

need_converge=0
if [ "$BD_PROBE_STATE" != "healthy" ]; then
  need_converge=1
elif [ "$tag_count" -ne 1 ]; then
  need_converge=1
elif ! bd_spec_matches; then
  need_converge=1
fi

if [ "$need_converge" -eq 1 ]; then
  bd_converge || die "failed to converge BetterDisplay virtual screen '${BD_DISPLAY_NAME}' (observed: ${BD_PROBE_OBSERVED-})"
fi
