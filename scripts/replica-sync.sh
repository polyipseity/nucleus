#!/usr/bin/env bash
# Pull-only replica sync (remote -> local). Intended for post-apply best-effort
# convergence from src/scripts/apply.sh and manual invocation via
# nucleus-replica-sync.

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

repo_root="${NUCLEUS_REPO_ROOT:-}"

usage() {
  usage_std "replica-sync.sh" "[--dry-run] [--replica-id ID] [--repo-root PATH]" "Synchronize enabled cloud replicas declared in src/modules/users.json. Pull-only: remote -> local."
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
# Method 4 (runtime direct read): replica-gc.json is consumed only by
# nucleus-owned scripts at runtime, not by third-party apps. No deployment
# step needed — the script reads directly from the repo tree via $REPO_ROOT.
REPLICA_GC_CONFIG_JSON="$REPO_ROOT/src/modules/configs/cloud/replica-gc.json"

if [ ! -f "$USERS_JSON" ]; then
  error "users registry not found at $USERS_JSON"
fi

if [ ! -f "$REPLICA_GC_CONFIG_JSON" ]; then
  error "gc config not found at $REPLICA_GC_CONFIG_JSON"
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq not found; cannot parse users.json"
fi

rclone_pass_path="$HOME/.config/nucleus/secrets/rclone-config-pass"
if [ -s "$rclone_pass_path" ]; then
  rclone_config_pass_value="$(cat "$rclone_pass_path")"
  export RCLONE_CONFIG_PASS="$rclone_config_pass_value"
fi

load_provider_gc_entries() {
  _provider="$1"
  _field="$2"

  jq -r --arg provider "$_provider" --arg field "$_field" '((.[$provider] // {})[$field] // [])[]' "$REPLICA_GC_CONFIG_JSON"
}

username="$(id -un)"
current_os="$(uname -s)"

replica_lines="$({
  jq -r --arg username "$username" '
    .[$username].cloudDrives.replicas // []
    | map(select(.enable == true))
    | .[]
    | [
        (.id // ""),
        (.direction // "pull"),
        (.localPath // ""),
        (.remotePath // "/"),
        (.provider // ""),
        (.iCloudService // "drive"),
        (.filtersFile // ""),
        (.readWrite // false),
        (.displayName // .id)
      ]
    | @tsv
  ' "$USERS_JSON"
} || true)" # check-suppress:suppression_doc: jq query may fail if users.json is missing; empty result handled by [ -z ] check downstream.

# check-suppress:suppression_doc: rclone remote may not be configured yet; probe expected to fail.
if [ -z "$replica_lines" ]; then
  say "no enabled replicas for user '$username'"
  exit 0
fi

run_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "would run: $*"
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
      --max-duration 1m 2>/dev/null || true)" # check-suppress:suppression_doc: rclone remote may not be configured yet; probe expected to fail.
  fi
  if [ -n "$_remote_dirs" ]; then
    printf '%s\n' "$_remote_dirs" | while IFS= read -r _remote_dir; do
      _remote_dir="${_remote_dir%/}"
      if [ -z "$_remote_dir" ]; then
        continue
      fi

      if should_skip_onedrive_root_entry "$_remote_dir" "$_blocked_root_entries"; then
        warn "[$_id] skipping inaccessible OneDrive root entry '$_remote_dir'"
        continue
      fi

      if remote_top_level_path_accessible "$_remote_ref" "$_remote_dir"; then
        record_unique_name "$_dir_entries_file" "$_remote_dir"
      else
        warn "[$_id] skipping inaccessible OneDrive root entry '$_remote_dir'"
      fi
    done
  fi

  if [ "$dry_run" = true ]; then
    _remote_files=""
  else
    _remote_files="$(rclone lsf "$_remote_ref" \
      --max-depth 1 --files-only --disable ListR --log-level ERROR \
      --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s \
      --max-duration 1m 2>/dev/null || true)" # check-suppress:suppression_doc: rclone remote may not be configured yet; probe expected to fail.
  fi
  if [ -n "$_remote_files" ]; then
    printf '%s\n' "$_remote_files" | while IFS= read -r _remote_file; do
      if should_skip_onedrive_root_entry "$_remote_file" "$_blocked_root_entries"; then
        warn "[$_id] skipping inaccessible OneDrive root entry '$_remote_file'"
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
      warn "[$_id] skipping inaccessible OneDrive root entry '$_local_name'"
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

gc_local_macos_artifacts() {
  _target_dir="$1"
  _file_globs="$2"
  _dir_names="$3"

  if [ ! -d "$_target_dir" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    dry_run "local metadata gc in $_target_dir"
    return 0
  fi

  for _pattern in $_file_globs; do
    find "$_target_dir" -type f -name "$_pattern" -delete
  done

  for _dir_name in $_dir_names; do
    find "$_target_dir" -type d -name "$_dir_name" -prune -exec rm -rf -- {} +
  done
}

ensure_macos_icloud_replica_symlink() {
  _relative_path="$1"
  _native_target="$HOME/Library/Mobile Documents"
  _replica_path="$HOME/$_relative_path"

  if [ ! -d "$_native_target" ]; then
    error "[iCloud] native target missing at $_native_target; cannot protect iCloudReplica symlink"
    return 1
  fi

  if [ -L "$_replica_path" ]; then
    _current_target="$(readlink "$_replica_path")"
    if [ "$_current_target" = "$_native_target" ]; then
      return 0
    fi
    if [ "$dry_run" = true ]; then
      dry_run "would update iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
      return 0
    fi
    rm "$_replica_path"
    ln -s "$_native_target" "$_replica_path"
    say "[iCloud] updated iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
    return 0
  fi

  if [ -e "$_replica_path" ]; then
    _backup_path="$_replica_path.pre-native-icloud.$(date +%Y%m%d%H%M%S)"
    if [ "$dry_run" = true ]; then
      dry_run "would move $_replica_path to $_backup_path and create symlink -> $_native_target"
      return 0
    fi
    mv "$_replica_path" "$_backup_path"
    ln -s "$_native_target" "$_replica_path"
    say "[iCloud] migrated $_replica_path to native iCloud symlink target $_native_target (backup: $_backup_path)"
    return 0
  fi

  if [ "$dry_run" = true ]; then
    dry_run "would create iCloudReplica symlink $_replica_path -> $_native_target"
    return 0
  fi

  ln -s "$_native_target" "$_replica_path"
  say "[iCloud] linked $_replica_path -> $_native_target"
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
    dry_run "unlock replica tree $_target_dir (owner write for sync run)"
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
    dry_run "lock replica tree $_target_dir (remove write perms)"
    return 0
  fi

  chmod -R a-w "$_target_dir"
}

failures=0

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

while IFS="$(printf '\t')" read -r id direction local_path remote_path provider icloud_service filters_file read_write display_name; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  if [ "$current_os" = "Darwin" ] && [ "$provider" = "iCloud" ] && [ "$id" = "iCloud" ]; then
    if ! ensure_macos_icloud_replica_symlink "$local_path"; then
      failures=$((failures + 1))
    fi
    say "[$display_name] skipping on macOS (native iCloud handles sync)"
    continue
  fi

  provider_file_globs="$(load_provider_gc_entries "$provider" "files")"
  provider_dir_names="$(load_provider_gc_entries "$provider" "dirs")"
  provider_remote_excludes="$(load_provider_gc_entries "$provider" "remoteExcludes")"
  provider_blocked_roots="$(load_provider_gc_entries "$provider" "blockedRoots")"

  if [ "$direction" != "pull" ]; then
    warn "[$display_name] unsupported direction '$direction'; replicas are pull-only by policy"
    failures=$((failures + 1))
    continue
  fi

  local_dir="$HOME/$local_path"
  remote_ref="$id:$remote_path"
  resolved_filters="$(resolve_filter_path "$filters_file")"
  runtime_filter_file=""

  mkdir -p "$local_dir"

  if ! set_replica_tree_writable "$local_dir"; then
    warn "[$display_name] failed to unlock replica tree '$local_dir'"
    failures=$((failures + 1))
    continue
  fi

  if [ -n "$resolved_filters" ] && [ ! -f "$resolved_filters" ]; then
    warn "filters file '$resolved_filters' not found for replica '$display_name'"
    if [ "$read_write" != "true" ]; then
      if ! set_replica_tree_read_only "$local_dir"; then
        warn "[$display_name] failed to re-lock replica tree '$local_dir' after filter validation failure"
        failures=$((failures + 1))
      fi
    fi
    failures=$((failures + 1))
    continue
  fi

  gc_local_macos_artifacts "$local_dir" "$provider_file_globs" "$provider_dir_names"

  set -- --log-level ERROR
  if [ "$provider" = "iCloud" ]; then
    set -- "$@" --iclouddrive-service "$icloud_service"
  fi
  if [ "$provider" = "OneDrive" ]; then
    if [ "$remote_path" = "/" ]; then
      # Keep the defensive root probe/filter generation for Personal Vault, but
      # let the real sync use OneDrive's default recursive listing path. For
      # full-root pull replicas, forcing --disable ListR makes syncs
      # pathologically slow.
      runtime_filter_file="$(build_onedrive_root_filter_file "$display_name" "$local_dir" "$remote_ref" "$provider_remote_excludes" "$provider_blocked_roots")"
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

  say "[$display_name] pull $remote_ref -> $local_dir"
  if ! run_cmd rclone sync "$remote_ref" "$local_dir" "$@"; then
    failures=$((failures + 1))
  fi

  if [ -n "$runtime_filter_file" ] && [ -f "$runtime_filter_file" ]; then
    rm -f "$runtime_filter_file"
  fi

  if [ "$read_write" != "true" ]; then
    if ! set_replica_tree_read_only "$local_dir"; then
      warn "[$display_name] failed to lock replica tree '$local_dir'"
      failures=$((failures + 1))
    fi
  fi
done < "$replica_lines_file"

rm -f "$replica_lines_file"

if [ "$failures" -gt 0 ]; then
  error "completed with $failures failure(s)"
  exit 1
fi

say "completed successfully"
