#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

# Arguments: replica_id [user_home]
replica_id="${1:?replica id required}"
user_home="${2:-${HOME}}"

NUCLEUS_REPO_ROOT="${NUCLEUS_REPO_ROOT:?NUCLEUS_REPO_ROOT not set — set in launchd/service environment}"

_nucleus_replica_cmd="${user_home}/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  die -l cloud-drives "nucleus replica command not found at $_nucleus_replica_cmd; run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run."
fi

exec "$_nucleus_replica_cmd" --replica-id "$replica_id"
