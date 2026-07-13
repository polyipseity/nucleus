#!/usr/bin/env bash
# Removes legacy per-replica state markers and local rclone cache directories
# so the next replica-sync run starts from a clean local state.
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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../src/scripts/lib.sh"

repo_root="${NUCLEUS_REPO_ROOT:-}"

usage() {
  usage_std "replica-reset.sh" "[--dry-run] [--replica-id ID] [--repo-root PATH]" "Reset local cloud replica sync state for manual troubleshooting. Local-only: never modifies remote data."
}

dry_run=false
replica_id_filter=""

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
USERS_JSON="$REPO_ROOT/src/modules/users.json"

if [ ! -f "$USERS_JSON" ]; then
  error "users registry not found at $USERS_JSON"
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq not found; cannot parse users.json"
fi

username="$(id -un)"
current_os="$(uname -s)"
# WHY: rclone remote may not be configured; best-effort unmount.
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
  ' "$USERS_JSON"
} || true)" # WHY: jq query may fail if users.json is missing; empty result handled by [ -z ] check downstream.

if [ -z "$replica_lines" ]; then
  say "no enabled replicas for user '$username'"
  exit 0
fi

run_local_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "would run: $*"
    return 0
  fi
  "$@"
}

legacy_replica_state_dirs="
$HOME/.config/nucleus/state/replica-bisync
$HOME/.config/nucleus/state/replica-sync
"
local_failures=0

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id local_path provider icloud_service; do
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
