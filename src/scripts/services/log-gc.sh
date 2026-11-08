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
# wrapper and the tests resolve it the same way gc.sh does.
_lgc_logs="${NUCLEUS_LOGS_BIN:-"$SCRIPT_DIR/../../../scripts/logs.sh"}"
exec "$_lgc_logs" gc --scope "$_lgc_scope"
