#!/usr/bin/env sh
# Synchronize enabled cloud replicas declared in src/modules/users.json.
#
# For each enabled replica of the current user:
#   - direction=pull         => rclone sync remote -> local
#   - direction=push         => rclone sync local  -> remote
#   - direction=bidirectional => rclone bisync local <-> remote
#
# Intended usage:
#   - Post-apply best-effort convergence from src/scripts/apply.sh
#   - Manual invocation via `nucleus-replica-bisync`

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
USERS_JSON="$REPO_ROOT/src/modules/users.json"

usage() {
  cat <<'EOF'
usage: replica-bisync.sh [--dry-run] [--replica-id ID]

  --dry-run         Print planned rclone commands without executing them.
  --replica-id ID   Restrict execution to a single replica id.
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
        printf '%s\n' "replica-bisync: --replica-id requires a value" >&2
        exit 1
      fi
      replica_id_filter="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' "replica-bisync: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$USERS_JSON" ]; then
  printf '%s\n' "replica-bisync: users registry not found at $USERS_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "replica-bisync: jq not found; cannot parse users.json" >&2
  exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
  printf '%s\n' "replica-bisync: rclone not found; skipping replica sync"
  exit 0
fi

# Export config passphrase when available so encrypted rclone.conf works
# in non-interactive contexts.
rclone_pass_path="$HOME/.config/nucleus/secrets/rclone-config-pass"
if [ -s "$rclone_pass_path" ]; then
  rclone_config_pass_value="$(cat "$rclone_pass_path")"
  export RCLONE_CONFIG_PASS="$rclone_config_pass_value"
fi

username="$(id -un)"

replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true and .remoteName != null))
    | .[]
    | [
        (.id // ""),
        (.direction // "bidirectional"),
        (.localPath // ""),
        (.remoteName // ""),
        (.remotePath // "/"),
        (.provider // ""),
        (.iCloudService // "drive"),
        (.filtersFile // "")
      ]
    | @tsv
  ' "$USERS_JSON"
} || true)"

if [ -z "$replica_lines" ]; then
  printf '%s\n' "replica-bisync: no enabled replicas for user '$username'"
  exit 0
fi

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'replica-bisync: [dry-run] '
    printf '%s ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

resolve_filter_path() {
  _candidate="$1"
  case "$_candidate" in
    "")
      printf '%s' ""
      ;;
    ~/*)
      printf '%s' "$HOME/${_candidate#~/}"
      ;;
    /*)
      printf '%s' "$_candidate"
      ;;
    *)
      printf '%s' "$HOME/$_candidate"
      ;;
  esac
}

failures=0

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id direction local_path remote_name remote_path provider icloud_service filters_file; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  local_dir="$HOME/$local_path"
  remote_ref="$remote_name:$remote_path"
  resolved_filters="$(resolve_filter_path "$filters_file")"

  mkdir -p "$local_dir"

  if [ -n "$resolved_filters" ]; then
    if [ ! -f "$resolved_filters" ]; then
      printf '%s\n' "replica-bisync: filters file '$resolved_filters' not found for replica '$id'" >&2
      failures=$((failures + 1))
      continue
    fi
  fi

  case "$direction" in
    pull)
      printf '%s\n' "replica-bisync: [$id] pull $remote_ref -> $local_dir"
      if [ "$provider" = "iCloud" ]; then
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone sync "$remote_ref" "$local_dir" --log-level ERROR --iclouddrive-service "$icloud_service" --filter-from "$resolved_filters"; then
            failures=$((failures + 1))
          fi
        else
          if ! run_cmd rclone sync "$remote_ref" "$local_dir" --log-level ERROR --iclouddrive-service "$icloud_service"; then
            failures=$((failures + 1))
          fi
        fi
      else
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone sync "$remote_ref" "$local_dir" --log-level ERROR --filter-from "$resolved_filters"; then
            failures=$((failures + 1))
          fi
        else
          if ! run_cmd rclone sync "$remote_ref" "$local_dir" --log-level ERROR; then
            failures=$((failures + 1))
          fi
        fi
      fi
      ;;
    push)
      printf '%s\n' "replica-bisync: [$id] push $local_dir -> $remote_ref"
      if [ "$provider" = "iCloud" ]; then
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone sync "$local_dir" "$remote_ref" --log-level ERROR --iclouddrive-service "$icloud_service" --filter-from "$resolved_filters"; then
            failures=$((failures + 1))
          fi
        else
          if ! run_cmd rclone sync "$local_dir" "$remote_ref" --log-level ERROR --iclouddrive-service "$icloud_service"; then
            failures=$((failures + 1))
          fi
        fi
      else
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone sync "$local_dir" "$remote_ref" --log-level ERROR --filter-from "$resolved_filters"; then
            failures=$((failures + 1))
          fi
        else
          if ! run_cmd rclone sync "$local_dir" "$remote_ref" --log-level ERROR; then
            failures=$((failures + 1))
          fi
        fi
      fi
      ;;
    bidirectional)
      printf '%s\n' "replica-bisync: [$id] bisync $local_dir <-> $remote_ref"
      if [ "$provider" = "iCloud" ]; then
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --iclouddrive-service "$icloud_service" --filter-from "$resolved_filters"; then
            if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --resync --iclouddrive-service "$icloud_service" --filter-from "$resolved_filters"; then
              failures=$((failures + 1))
            fi
          fi
        else
          if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --iclouddrive-service "$icloud_service"; then
            if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --resync --iclouddrive-service "$icloud_service"; then
              failures=$((failures + 1))
            fi
          fi
        fi
      else
        if [ -n "$resolved_filters" ]; then
          if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --filter-from "$resolved_filters"; then
            if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --resync --filter-from "$resolved_filters"; then
              failures=$((failures + 1))
            fi
          fi
        else
          if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access; then
            if ! run_cmd rclone bisync "$local_dir" "$remote_ref" --log-level ERROR --check-access --resync; then
              failures=$((failures + 1))
            fi
          fi
        fi
      fi
      ;;
    *)
      printf '%s\n' "replica-bisync: unsupported direction '$direction' for replica '$id'" >&2
      failures=$((failures + 1))
      ;;
  esac
done < "$replica_lines_file"

rm -f "$replica_lines_file"

if [ "$failures" -gt 0 ]; then
  printf '%s\n' "replica-bisync: completed with $failures failure(s)" >&2
  exit 1
fi

printf '%s\n' "replica-bisync: completed successfully"
