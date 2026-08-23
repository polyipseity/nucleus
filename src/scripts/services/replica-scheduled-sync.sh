#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Arguments: replica_id
replica_id="${1:?replica id required}"

NUCLEUS_REPO_ROOT="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set — set in launchd/service environment}"

_cloud_sync_script="$NUCLEUS_REPO_ROOT/scripts/cloud.sh"
if [ ! -x "$_cloud_sync_script" ]; then
  die -l cloud-drives "cloud sync script not found at $_cloud_sync_script; run nucleus apply to materialize scripts/cloud.sh before scheduled replica syncs run."
fi

exec "$_cloud_sync_script" sync --replica-id "$replica_id" --repo-root "$NUCLEUS_REPO_ROOT"
