#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Configuration via environment variables (set by writeNucleusShellApplication extraEnv):
#   NUCLEUS_REPLICA_ID  — replica identifier for the sync operation
#   NUCLEUS_USER_HOME   — user home directory path
replica_id="${NUCLEUS_REPLICA_ID:?NUCLEUS_REPLICA_ID required}"

REPO_ROOT="${NUCLEUS_REPO_ROOT:-$(derive_repo_root)}"
export NUCLEUS_REPO_ROOT="$REPO_ROOT"

_cloud_sync_script="$REPO_ROOT/scripts/cloud.sh"
if [ ! -x "$_cloud_sync_script" ]; then
  die -l cloud-drives "cloud sync script not found at $_cloud_sync_script; run nucleus apply to materialize scripts/cloud.sh before scheduled replica syncs run."
fi

exec "$_cloud_sync_script" sync --replica-id "$replica_id" --repo-root "$NUCLEUS_REPO_ROOT"
