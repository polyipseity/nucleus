#!/usr/bin/env bash
set -eu

NUCLEUS_REPO_ROOT="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set — set in launchd/service environment}"

# CURRENT_USER_HOME and REPLICA_ID are build-time tokens substituted by
# cloud-drives.nix's mkReplicaScheduledSyncScript.
_nucleus_replica_cmd="__CURRENT_USER_HOME__/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  echo "cloud-drives: nucleus replica command not found at $_nucleus_replica_cmd" >&2
  echo "cloud-drives: run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run." >&2
  exit 1
fi

exec "$_nucleus_replica_cmd" --replica-id "__REPLICA_ID__"
