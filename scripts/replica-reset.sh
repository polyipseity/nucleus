#!/usr/bin/env sh
# Reset local cloud replica bisync state for manual troubleshooting.
#
# This command is intentionally local-only: it never modifies remote data.
# It removes per-replica seed markers, local RCLONE_TEST files, and local
# rclone bisync cache directories so the next replica-bisync run starts from a
# clean local state.
#
# Intended usage:
#   - Manual troubleshooting via `nucleus-replica-reset`
#   - Repro steps before validating `nucleus-replica-bisync`

set -eu

# Locate the nucleus repository root. Resolution order:
#   1. ~/.config/nucleus/repo-root — written by apply.sh; reliable from
#      anywhere once apply has been run at least once.
#   2. git rev-parse --show-toplevel — works when CWD is inside the repo.
#      Stderr is suppressed because non-repo CWD is expected and benign.
#   3. ~/dev/nucleus — canonical clone location declared in devRepos config.
resolve_nucleus_root() {
  _rnr_config_file="$HOME/.config/nucleus/repo-root"
  if [ -f "$_rnr_config_file" ]; then
    _rnr_root="$(cat "$_rnr_config_file")"
    if [ -n "$_rnr_root" ] && [ -d "$_rnr_root" ]; then
      printf '%s\n' "$_rnr_root"
      return 0
    fi
  fi
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    if [ -n "$_rnr_git_root" ] && [ -d "$_rnr_git_root" ]; then
      printf '%s\n' "$_rnr_git_root"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}

REPO_ROOT="$(resolve_nucleus_root)"
USERS_JSON="$REPO_ROOT/src/modules/users.json"

usage() {
  cat <<'EOF'
usage: replica-reset.sh [--dry-run] [--replica-id ID]

  --dry-run         Print planned reset actions without modifying local state.
  --replica-id ID   Restrict marker/RCLONE_TEST cleanup to one replica id.

Notes:
  - This command resets LOCAL bisync state only; remotes are never modified.
  - The rclone bisync cache directory is always cleared because state files are
    not reliably attributable to a single replica id.
EOF
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
        printf '%s\n' "replica-reset: --replica-id requires a value" >&2
        exit 1
      fi
      replica_id_filter="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' "replica-reset: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$USERS_JSON" ]; then
  printf '%s\n' "replica-reset: users registry not found at $USERS_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "replica-reset: jq not found; cannot parse users.json" >&2
  exit 1
fi

username="$(id -un)"
replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true and .remoteName != null))
    | .[]
    | [
        (.id // ""),
        (.localPath // "")
      ]
    | @tsv
  ' "$USERS_JSON"
} || true)"

if [ -z "$replica_lines" ]; then
  printf '%s\n' "replica-reset: no enabled replicas for user '$username'"
  exit 0
fi

run_local_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'replica-reset: [dry-run] '
    printf '%s ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

replica_state_dir="$HOME/.config/nucleus/state/replica-bisync"
local_failures=0

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id local_path; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  state_marker="$replica_state_dir/$id.seeded"
  if [ -f "$state_marker" ]; then
    if ! run_local_cmd rm -f "$state_marker"; then
      local_failures=$((local_failures + 1))
    fi
  fi

  # rclone bisync check-access may create a local RCLONE_TEST file. Removing it
  # keeps manual seed validation deterministic after reset.
  local_root="$HOME/$local_path"
  local_check_marker="$local_root/RCLONE_TEST"
  if [ -f "$local_check_marker" ]; then
    if ! run_local_cmd rm -f "$local_check_marker"; then
      local_failures=$((local_failures + 1))
    fi
  fi
done < "$replica_lines_file"

rm -f "$replica_lines_file"

# Reset rclone's local bisync cache to clear lock/listing state.
for cache_dir in "$HOME/.cache/rclone/bisync" "$HOME/.cache/rclone/bisync-lock"; do
  if [ -d "$cache_dir" ]; then
    if ! run_local_cmd rm -rf "$cache_dir"; then
      local_failures=$((local_failures + 1))
    fi
  fi
done

if [ "$local_failures" -gt 0 ]; then
  printf '%s\n' "replica-reset: completed with $local_failures failure(s)" >&2
  exit 1
fi

printf '%s\n' "replica-reset: completed successfully"
