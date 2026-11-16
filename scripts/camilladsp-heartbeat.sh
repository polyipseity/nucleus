#!/usr/bin/env bash
# camilladsp-heartbeat.sh - nucleus command entrypoint for the CamillaDSP heartbeat.
#
# Delegates to the service implementation so help, flags, and behavior stay in one place.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="${NUCLEUS_REPO_ROOT:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
exec bash "$REPO_ROOT/src/scripts/services/camilladsp-heartbeat.sh" "$@"
