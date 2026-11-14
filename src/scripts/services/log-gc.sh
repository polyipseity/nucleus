#!/usr/bin/env bash
# Rotate and expire one nucleus log tree, selected by scope.
# Usage: log-gc.sh <user|system>
# The system tree is root-owned (linux-builder, service-watchdog), so its callers
# run this script in the system domain; the user tree runs as the user. The
# operations themselves belong to nucleus-logs; this wrapper only selects scope.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_lgc_scope="${1:-}"
case "$_lgc_scope" in
user | system) ;;
*) die "usage: log-gc.sh <user|system>" ;;
esac

# WHY NUCLEUS_LOGS_BIN: one seam for the app entry point, so the scheduled-task
# wrapper and the tests resolve it the same way gc.sh does. Without it the entry
# point comes from the live checkout, because a bundled app has no scripts/ tree
# beside script-tree.
if [ -n "${NUCLEUS_LOGS_BIN:-}" ]; then
  _lgc_logs="$NUCLEUS_LOGS_BIN"
else
  if ! _lgc_root="$(derive_repo_root)"; then
    die "cannot resolve the nucleus repository root; set NUCLEUS_LOGS_BIN or write the live checkout path to the system repo-root file"
  fi
  _lgc_logs="$_lgc_root/scripts/logs.sh"
fi
exec "$_lgc_logs" gc --scope "$_lgc_scope"
