set -eu

# Eval-time fallback for launchd jobs that don't inherit apply.sh env.
_repo_root="__REPO_ROOT__"
if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
  _repo_root="${NUCLEUS_REPO_ROOT:?cloud-drives: NUCLEUS_REPO_ROOT not set; run via apply.sh}"
fi
_nucleus_replica_cmd="__CURRENT_USER_HOME__/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  echo "cloud-drives: nucleus replica command not found at $_nucleus_replica_cmd" >&2
  echo "cloud-drives: run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run." >&2
  exit 1
fi

exec "$_nucleus_replica_cmd" --replica-id "__REPLICA_ID__"
