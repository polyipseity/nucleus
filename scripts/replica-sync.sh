#!/usr/bin/env sh
# Synchronize enabled cloud replicas declared in src/modules/users.json.
#
# Replica policy in this repository is pull-only:
#   - remote -> local only (`rclone sync remote local`)
#   - no push and no bisync paths
#
# Intended usage:
#   - Post-apply best-effort convergence from src/scripts/apply.sh
#   - Manual invocation via `nucleus-replica-sync`

set -eu

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
REPLICA_CLEANUP_CONFIG_JSON="$REPO_ROOT/src/modules/configs/cloud/replica-cleanup.json"

usage() {
  cat <<'EOF'
usage: replica-sync.sh [--dry-run] [--replica-id ID]

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
        printf '%s\n' "replica-sync: --replica-id requires a value" >&2
        exit 1
      fi
      replica_id_filter="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' "replica-sync: unsupported argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$USERS_JSON" ]; then
  printf '%s\n' "replica-sync: users registry not found at $USERS_JSON" >&2
  exit 1
fi

if [ ! -f "$REPLICA_CLEANUP_CONFIG_JSON" ]; then
  printf '%s\n' "replica-sync: cleanup config not found at $REPLICA_CLEANUP_CONFIG_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "replica-sync: jq not found; cannot parse users.json" >&2
  exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
  printf '%s\n' "replica-sync: rclone not found; skipping replica sync"
  exit 0
fi

rclone_pass_path="$HOME/.config/nucleus/secrets/rclone-config-pass"
if [ -s "$rclone_pass_path" ]; then
  rclone_config_pass_value="$(cat "$rclone_pass_path")"
  export RCLONE_CONFIG_PASS="$rclone_config_pass_value"
fi

load_provider_cleanup_entries() {
  _provider="$1"
  _field="$2"

  jq -r --arg provider "$_provider" --arg field "$_field" '((.[$provider] // {})[$field] // [])[]' "$REPLICA_CLEANUP_CONFIG_JSON"
}

username="$(id -un)"
current_os="$(uname -s)"

replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true and .remoteName != null))
    | .[]
    | [
        (.id // ""),
        (.direction // "pull"),
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
  printf '%s\n' "replica-sync: no enabled replicas for user '$username'"
  exit 0
fi

run_cmd() {
  if [ "$dry_run" = true ]; then
    printf 'replica-sync: [dry-run] '
    printf '%s ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

record_unique_name() {
  _list_file="$1"
  _name="$2"

  if [ -z "$_name" ]; then
    return 0
  fi

  if [ ! -f "$_list_file" ] || ! grep -Fxq "$_name" "$_list_file"; then
    printf '%s\n' "$_name" >> "$_list_file"
  fi
}

remote_top_level_path_accessible() {
  _remote_ref="$1"
  _entry_name="$2"

  _probe_remote_ref="${_remote_ref%/}/$_entry_name"

  rclone lsf "$_probe_remote_ref" \
    --max-depth 1 --disable ListR --log-level ERROR \
    --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s \
    --max-duration 1m >/dev/null 2>&1
}

should_skip_onedrive_root_entry() {
  _entry_name="$1"
  _blocked_root_entries="$2"
  _entry_lc="$(printf '%s' "$_entry_name" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$_blocked_root_entries" ]; then
    return 1
  fi

  printf '%s\n' "$_blocked_root_entries" | grep -Fxq "$_entry_lc"
}

build_onedrive_root_filter_file() {
  _id="$1"
  _local_dir="$2"
  _remote_ref="$3"
  _remote_excludes="$4"
  _blocked_root_entries="$5"

  _filter_file="$(mktemp)"
  _dir_entries_file="$(mktemp)"
  _file_entries_file="$(mktemp)"

  : > "$_filter_file"
  for _pattern in $_remote_excludes; do
    printf -- '- %s\n' "$_pattern" >> "$_filter_file"
  done

  if [ "$dry_run" = true ]; then
    _remote_dirs=""
  else
    _remote_dirs="$(rclone lsf "$_remote_ref" \
      --max-depth 1 --dirs-only --disable ListR --log-level ERROR \
      --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s \
      --max-duration 1m 2>/dev/null || true)"
  fi
  if [ -n "$_remote_dirs" ]; then
    printf '%s\n' "$_remote_dirs" | while IFS= read -r _remote_dir; do
      _remote_dir="${_remote_dir%/}"
      if [ -z "$_remote_dir" ]; then
        continue
      fi

      if should_skip_onedrive_root_entry "$_remote_dir" "$_blocked_root_entries"; then
        printf '%s\n' "replica-sync: [$_id] skipping inaccessible OneDrive root entry '$_remote_dir'" >&2
        continue
      fi

      if remote_top_level_path_accessible "$_remote_ref" "$_remote_dir"; then
        record_unique_name "$_dir_entries_file" "$_remote_dir"
      else
        printf '%s\n' "replica-sync: [$_id] skipping inaccessible OneDrive root entry '$_remote_dir'" >&2
      fi
    done
  fi

  if [ "$dry_run" = true ]; then
    _remote_files=""
  else
    _remote_files="$(rclone lsf "$_remote_ref" \
      --max-depth 1 --files-only --disable ListR --log-level ERROR \
      --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s \
      --max-duration 1m 2>/dev/null || true)"
  fi
  if [ -n "$_remote_files" ]; then
    printf '%s\n' "$_remote_files" | while IFS= read -r _remote_file; do
      if should_skip_onedrive_root_entry "$_remote_file" "$_blocked_root_entries"; then
        printf '%s\n' "replica-sync: [$_id] skipping inaccessible OneDrive root entry '$_remote_file'" >&2
        continue
      fi
      record_unique_name "$_file_entries_file" "$_remote_file"
    done
  fi

  for _local_entry in "$_local_dir"/* "$_local_dir"/.[!.]* "$_local_dir"/..?*; do
    if [ ! -e "$_local_entry" ]; then
      continue
    fi

    _local_name="$(basename "$_local_entry")"
    if should_skip_onedrive_root_entry "$_local_name" "$_blocked_root_entries"; then
      printf '%s\n' "replica-sync: [$_id] skipping inaccessible OneDrive root entry '$_local_name'" >&2
      continue
    fi
    if [ -d "$_local_entry" ]; then
      record_unique_name "$_dir_entries_file" "$_local_name"
    else
      record_unique_name "$_file_entries_file" "$_local_name"
    fi
  done

  if [ -f "$_dir_entries_file" ]; then
    while IFS= read -r _dir_name; do
      if [ -z "$_dir_name" ]; then
        continue
      fi
      printf '+ /%s/\n' "$_dir_name" >> "$_filter_file"
      printf '+ /%s/**\n' "$_dir_name" >> "$_filter_file"
    done < "$_dir_entries_file"
  fi

  if [ -f "$_file_entries_file" ]; then
    while IFS= read -r _file_name; do
      if [ -z "$_file_name" ]; then
        continue
      fi
      printf '+ /%s\n' "$_file_name" >> "$_filter_file"
    done < "$_file_entries_file"
  fi

  printf '%s\n' '- **' >> "$_filter_file"

  rm -f "$_dir_entries_file" "$_file_entries_file"
  printf '%s\n' "$_filter_file"
}

cleanup_local_macos_artifacts() {
  _target_dir="$1"
  _file_globs="$2"
  _dir_names="$3"

  if [ ! -d "$_target_dir" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-sync: [dry-run] local metadata cleanup in $_target_dir"
    return 0
  fi

  for _pattern in $_file_globs; do
    find "$_target_dir" -type f -name "$_pattern" -delete
  done

  for _dir_name in $_dir_names; do
    find "$_target_dir" -type d -name "$_dir_name" -prune -exec rm -rf {} +
  done
}

ensure_macos_icloud_replica_symlink() {
  _relative_path="$1"
  _native_target="$HOME/Library/Mobile Documents"
  _replica_path="$HOME/$_relative_path"

  if [ ! -d "$_native_target" ]; then
    printf '%s\n' "replica-sync: [iCloud] native target missing at $_native_target; cannot protect iCloudReplica symlink" >&2
    return 1
  fi

  if [ -L "$_replica_path" ]; then
    _current_target="$(readlink "$_replica_path")"
    if [ "$_current_target" = "$_native_target" ]; then
      return 0
    fi
    if [ "$dry_run" = true ]; then
      printf '%s\n' "replica-sync: [dry-run] would update iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
      return 0
    fi
    rm "$_replica_path"
    ln -s "$_native_target" "$_replica_path"
    printf '%s\n' "replica-sync: [iCloud] updated iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
    return 0
  fi

  if [ -e "$_replica_path" ]; then
    _backup_path="$_replica_path.pre-native-icloud.$(date +%Y%m%d%H%M%S)"
    if [ "$dry_run" = true ]; then
      printf '%s\n' "replica-sync: [dry-run] would move $_replica_path to $_backup_path and create symlink -> $_native_target"
      return 0
    fi
    mv "$_replica_path" "$_backup_path"
    ln -s "$_native_target" "$_replica_path"
    printf '%s\n' "replica-sync: [iCloud] migrated $_replica_path to native iCloud symlink target $_native_target (backup: $_backup_path)"
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-sync: [dry-run] would create iCloudReplica symlink $_replica_path -> $_native_target"
    return 0
  fi

  ln -s "$_native_target" "$_replica_path"
  printf '%s\n' "replica-sync: [iCloud] linked $_replica_path -> $_native_target"
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

# Replica directories are treated as read-only snapshots outside sync runs.
# Temporarily grant owner write access for convergence, then remove write bits
# to prevent create/modify/delete operations between runs.
set_replica_tree_writable() {
  _target_dir="$1"

  if [ ! -d "$_target_dir" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-sync: [dry-run] unlock replica tree $_target_dir (owner write for sync run)"
    return 0
  fi

  chmod u+w "$_target_dir"
  find "$_target_dir" -type d -exec chmod u+rwx {} +
  find "$_target_dir" -type f -exec chmod u+rw {} +
}

set_replica_tree_read_only() {
  _target_dir="$1"

  if [ ! -d "$_target_dir" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-sync: [dry-run] lock replica tree $_target_dir (remove write perms)"
    return 0
  fi

  chmod -R a-w "$_target_dir"
}

failures=0

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id direction local_path remote_name remote_path provider icloud_service filters_file; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  if [ "$current_os" = "Darwin" ] && [ "$provider" = "iCloud" ] && [ "$id" = "iCloud" ]; then
    if ! ensure_macos_icloud_replica_symlink "$local_path"; then
      failures=$((failures + 1))
    fi
    printf '%s\n' "replica-sync: [$id] skipping on macOS (native iCloud handles sync)"
    continue
  fi

  provider_file_globs="$(load_provider_cleanup_entries "$provider" "files")"
  provider_dir_names="$(load_provider_cleanup_entries "$provider" "dirs")"
  provider_remote_excludes="$(load_provider_cleanup_entries "$provider" "remoteExcludes")"
  provider_blocked_roots="$(load_provider_cleanup_entries "$provider" "blockedRoots")"

  if [ "$direction" != "pull" ]; then
    printf '%s\n' "replica-sync: [$id] unsupported direction '$direction'; replicas are pull-only by policy" >&2
    failures=$((failures + 1))
    continue
  fi

  local_dir="$HOME/$local_path"
  remote_ref="$remote_name:$remote_path"
  resolved_filters="$(resolve_filter_path "$filters_file")"
  runtime_filter_file=""

  mkdir -p "$local_dir"

  if ! set_replica_tree_writable "$local_dir"; then
    printf '%s\n' "replica-sync: [$id] failed to unlock replica tree '$local_dir'" >&2
    failures=$((failures + 1))
    continue
  fi

  if [ -n "$resolved_filters" ] && [ ! -f "$resolved_filters" ]; then
    printf '%s\n' "replica-sync: filters file '$resolved_filters' not found for replica '$id'" >&2
    if ! set_replica_tree_read_only "$local_dir"; then
      printf '%s\n' "replica-sync: [$id] failed to re-lock replica tree '$local_dir' after filter validation failure" >&2
      failures=$((failures + 1))
    fi
    failures=$((failures + 1))
    continue
  fi

  cleanup_local_macos_artifacts "$local_dir" "$provider_file_globs" "$provider_dir_names"

  set -- --log-level ERROR
  if [ "$provider" = "iCloud" ]; then
    set -- "$@" --iclouddrive-service "$icloud_service"
  fi
  if [ "$provider" = "OneDrive" ]; then
    # OneDrive root pulls can stall with backend chunk/transfer pressure even
    # though this workflow is read-only. Keep syncs conservative and stable.
    set -- "$@" --checkers 1 --transfers 1 --onedrive-chunk-size 320Ki
    if [ "$remote_path" = "/" ]; then
      # Keep the defensive root probe/filter generation for Personal Vault, but
      # let the real sync use OneDrive's recursive listing path. For full-root
      # pull replicas, forcing --disable ListR makes syncs pathologically slow.
      runtime_filter_file="$(build_onedrive_root_filter_file "$id" "$local_dir" "$remote_ref" "$provider_remote_excludes" "$provider_blocked_roots")"
      if [ -n "$resolved_filters" ]; then
        set -- "$@" --filter-from "$resolved_filters"
      fi
      set -- "$@" --filter-from "$runtime_filter_file"
    elif [ -n "$resolved_filters" ]; then
      set -- "$@" --filter-from "$resolved_filters"
    fi
  else
    for _pattern in $provider_remote_excludes; do
      set -- "$@" --exclude "$_pattern"
    done
    if [ -n "$resolved_filters" ]; then
      set -- "$@" --filter-from "$resolved_filters"
    fi
  fi

  printf '%s\n' "replica-sync: [$id] pull $remote_ref -> $local_dir"
  if ! run_cmd rclone sync "$remote_ref" "$local_dir" "$@"; then
    failures=$((failures + 1))
  fi

  if [ -n "$runtime_filter_file" ] && [ -f "$runtime_filter_file" ]; then
    rm -f "$runtime_filter_file"
  fi

  if ! set_replica_tree_read_only "$local_dir"; then
    printf '%s\n' "replica-sync: [$id] failed to lock replica tree '$local_dir'" >&2
    failures=$((failures + 1))
  fi
done < "$replica_lines_file"

rm -f "$replica_lines_file"

if [ "$failures" -gt 0 ]; then
  printf '%s\n' "replica-sync: completed with $failures failure(s)" >&2
  exit 1
fi

printf '%s\n' "replica-sync: completed successfully"
