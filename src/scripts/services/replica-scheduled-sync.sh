#!/usr/bin/env bash
set -eu

# Arguments: replica_id [user_home]
replica_id="${1:?replica id required}"
user_home="${2:-${HOME}}"

NUCLEUS_REPO_ROOT="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set — set in launchd/service environment}"

_nucleus_replica_cmd="${user_home}/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  echo "cloud-drives: nucleus replica command not found at $_nucleus_replica_cmd" >&2
  echo "cloud-drives: run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run." >&2
  exit 1
fi

exec "$_nucleus_replica_cmd" --replica-id "$replica_id"
