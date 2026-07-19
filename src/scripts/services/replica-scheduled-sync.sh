set -eu

# __REPO_ROOT__ is substituted at build time by Nix.  Hard-fail if
# the token was not substituted.
_repo_root="__REPO_ROOT__"
if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
  echo "cloud-drives: __REPO_ROOT__ is empty or not a directory — set NUCLEUS_REPO_ROOT at build time" >&2
  exit 1
fi
_nucleus_replica_cmd="__CURRENT_USER_HOME__/.nix-profile/bin/nucleus-replica-sync"
if [ ! -x "$_nucleus_replica_cmd" ]; then
  echo "cloud-drives: nucleus replica command not found at $_nucleus_replica_cmd" >&2
  echo "cloud-drives: run home-manager switch/apply to install nucleus-replica-sync before scheduled replica syncs run." >&2
  exit 1
fi

exec "$_nucleus_replica_cmd" --replica-id "__REPLICA_ID__"
