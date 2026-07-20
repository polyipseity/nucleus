set -eu

# require_repo_root() is provided via repo-root-lib.sh (prepended at build time).
require_repo_root cloud-drives

_nucleus_replica_cmd="__CURRENT_USER_HOME__/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  echo "cloud-drives: nucleus replica command not found at $_nucleus_replica_cmd" >&2
  echo "cloud-drives: run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run." >&2
  exit 1
fi

exec "$_nucleus_replica_cmd" --replica-id "__REPLICA_ID__"
