#!/usr/bin/env bash
# Removes legacy per-replica state markers and local rclone cache directories
# so the next replica-sync run starts from a clean local state.
#
# Usage: nucleus-replica-reset [--dry-run] [--replica-id ID] [--repo-root PATH]
#
# Env vars: NUCLEUS_REPO_ROOT — repo checkout used to find src/users/ when
# --repo-root is not given.
#
# Safety: local-only by design — never modifies remote data.  With --dry-run
# the planned commands are printed instead of executed.  Exits non-zero if
# any local removal fails.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR works from Nix wrapper symlinks.
_self="$0"
if [ -h "$_self" ]; then
  _target="$(readlink "$_self")"
  case "$_target" in
    /*) _self="$_target" ;;
    *) _self="$(dirname "$_self")/$_target" ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

# WHY: NUCLEUS_REPO_ROOT lets non-standard checkouts (e.g. CI or a workspace
# copy) locate the user registry without assuming cwd.
repo_root="${NUCLEUS_REPO_ROOT:-}"

# usage — Print the help text.
# WHY: the help states the local-only guarantee up front so the safety
# contract is visible before any flag is parsed.
usage() {
  usage_std "replica-reset.sh" "[--dry-run] [--replica-id ID] [--repo-root PATH]" "Reset local cloud replica sync state for manual troubleshooting. Local-only: never modifies remote data."
}

dry_run=false
replica_id_filter=""

# WHY: flags are parsed strictly — unknown arguments abort so a typo can
# never silently reset the wrong replica set.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --replica-id)
      shift
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        error "--replica-id requires a value"
        exit 1
      fi
      replica_id_filter="$1"
      ;;
    --repo-root)
      shift
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        error "--repo-root requires a value"
        exit 1
      fi
      repo_root="$1"
      ;;
    --repo-root=*)
      repo_root="${1#--repo-root=}"
      if [ -z "$repo_root" ]; then
        error "--repo-root requires a non-empty value"
        exit 1
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$repo_root" ]; then
  REPO_ROOT="$(derive_repo_root)"
else
  REPO_ROOT="$repo_root"
fi

_load_users_registry() {
  "$REPO_ROOT/src/scripts/lib/load-user-registry.sh" \
    --host "$(resolve_nucleus_host)" \
    --repo-root "$REPO_ROOT"
}

USERS_REGISTRY_ROOT="$REPO_ROOT/src/users"

if [ ! -d "$USERS_REGISTRY_ROOT" ]; then
  error "users registry root not found at $USERS_REGISTRY_ROOT"
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq not found; cannot parse user registry"
fi

USERS_REGISTRY="$(_load_users_registry)"

username="$(id -un)"
current_os="$(uname -s)"
# check-suppress:suppression_doc: rclone remote may not be configured; best-effort unmount.
# WHY: the query filters to enabled replicas that name a remote — a replica
# without a configured remote has nothing to reset, and disabled replicas
# must not be touched.
replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true and .remoteName != null))
    | .[]
    | [
        (.id // ""),
        (.localPath // ""),
        (.provider // ""),
        (.iCloudService // "drive")
      ]
    | @tsv
  ' <<< "$USERS_REGISTRY"
} || true)" # check-suppress:suppression_doc: jq query may fail if user registry is missing; empty result handled by [ -z ] check downstream.

if [ -z "$replica_lines" ]; then
  say "no enabled replicas for user '$username'"
  exit 0
fi

# run_local_cmd — Execute a destructive command, honoring --dry-run.
# Args: $@ — the command and its arguments.
# Output: with --dry-run, prints the planned command instead of running it.
# WHY: routing every removal through this helper keeps the dry-run guarantee
# structural rather than relying on each call site to check the flag.
run_local_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "would run: $*"
    return 0
  fi
  "$@"
}

# WHY: these dirs hold seeding markers from the pre-unified-sync layouts;
# they are removed so a stale marker cannot make the next sync skip seeding.
legacy_replica_state_dirs="
$HOME/.config/nucleus/state/replica-bisync
$HOME/.config/nucleus/state/replica-sync
"
local_failures=0

# WHY: the replica list is materialized to a temp file (rather than piped or
# process-substituted) so the loop below can read from a stable fd while its
# body runs commands that also consume stdin.
replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

while IFS="$(printf '\t')" read -r id local_path provider icloud_service; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  for state_dir in $legacy_replica_state_dirs; do
    state_marker="$state_dir/$id.seeded"
    if [ -f "$state_marker" ]; then
      if ! run_local_cmd rm -f "$state_marker"; then
        local_failures=$((local_failures + 1))
      fi
    fi
  done

  local_root="$HOME/$local_path"

  # macOS iCloud Drive replicas are represented as symlinks to the native
  # CloudDocs path. Never recurse into that target during reset; only remove
  # the symlink itself so remotes and native-managed content remain untouched.
  if [ "$current_os" = "Darwin" ] && [ "$provider" = "iCloud" ] && [ "$icloud_service" = "drive" ]; then
    if [ -L "$local_root" ]; then
      if ! run_local_cmd rm -f "$local_root"; then
        local_failures=$((local_failures + 1))
      fi
    elif [ -e "$local_root" ]; then
      warn "[$id] expected iCloud drive symlink at '$local_root'; leaving non-symlink path untouched"
    fi
    continue
  fi

  # For non-exception replicas, reset means clearing local replica data only.
  # Note: If tree is locked read-only (from previous sync), unlock it first.
  if [ -e "$local_root" ] || [ -L "$local_root" ]; then
    # WHY: a previous sync can leave the tree read-only; u+w is restored
    # before rm so removal succeeds.  Failure is tolerated because the path
    # may be a symlink or already writable.
    if ! run_local_cmd chmod -R u+w "$local_root" 2>/dev/null; then
      : # Ignore chmod errors (may be symlink or already writable)
    fi
    if ! run_local_cmd rm -rf -- "$local_root"; then
      local_failures=$((local_failures + 1))
      continue
    fi
  fi

done < "$replica_lines_file"

rm -f "$replica_lines_file"

# Reset rclone's local cache directories to clear stale sync state.
# rclone cache roots vary by platform/runtime:
# - Linux/most POSIX shells: ~/.cache/rclone
# - macOS native builds: ~/Library/Caches/rclone
for cache_dir in \
  "$HOME/.cache/rclone/bisync" \
  "$HOME/.cache/rclone/bisync-lock" \
  "$HOME/.cache/rclone/sync" \
  "$HOME/.cache/rclone/sync-lock" \
  "$HOME/Library/Caches/rclone/bisync" \
  "$HOME/Library/Caches/rclone/bisync-lock" \
  "$HOME/Library/Caches/rclone/sync" \
  "$HOME/Library/Caches/rclone/sync-lock"; do
  if [ -d "$cache_dir" ]; then
    if ! run_local_cmd rm -rf -- "$cache_dir"; then
      local_failures=$((local_failures + 1))
    fi
  fi
done

if [ "$local_failures" -gt 0 ]; then
  error "completed with $local_failures failure(s)"
fi

say "completed successfully"
