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
REPLICA_CLEANUP_CONFIG_JSON="$REPO_ROOT/src/modules/configs/cloud/replica-cleanup.json"

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

if [ ! -f "$REPLICA_CLEANUP_CONFIG_JSON" ]; then
  printf '%s\n' "replica-bisync: cleanup config not found at $REPLICA_CLEANUP_CONFIG_JSON" >&2
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
current_os="$(uname -s)"
macos_metadata_file_globs="$(jq -r '.macOSMetadata.fileGlobs[]' "$REPLICA_CLEANUP_CONFIG_JSON")"
macos_metadata_dir_names="$(jq -r '.macOSMetadata.directoryNames[]' "$REPLICA_CLEANUP_CONFIG_JSON")"
macos_metadata_remote_filters="$(jq -r '.macOSMetadata.remoteFilterGlobs[]' "$REPLICA_CLEANUP_CONFIG_JSON")"
onedrive_inaccessible_entries_lc="$(jq -r '.oneDrive.inaccessibleRootEntries[] | ascii_downcase' "$REPLICA_CLEANUP_CONFIG_JSON")"

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
  _entry_lc="$(printf '%s' "$_entry_name" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$onedrive_inaccessible_entries_lc" ]; then
    return 1
  fi

  printf '%s\n' "$onedrive_inaccessible_entries_lc" | grep -Fxq "$_entry_lc"
}

build_onedrive_root_filter_file() {
  _id="$1"
  _local_dir="$2"
  _remote_ref="$3"

  _filter_file="$(mktemp)"
  _dir_entries_file="$(mktemp)"
  _file_entries_file="$(mktemp)"

  # Exclude shared metadata patterns first so they never enter allowlisted
  # replica traversals regardless of which host created them.
  : > "$_filter_file"
  for _pattern in $macos_metadata_remote_filters; do
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

      if should_skip_onedrive_root_entry "$_remote_dir"; then
        printf '%s\n' "replica-bisync: [$_id] skipping inaccessible OneDrive root entry '$_remote_dir'" >&2
        continue
      fi

      if remote_top_level_path_accessible "$_remote_ref" "$_remote_dir"; then
        record_unique_name "$_dir_entries_file" "$_remote_dir"
      else
        printf '%s\n' "replica-bisync: [$_id] skipping inaccessible OneDrive root entry '$_remote_dir'" >&2
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
      if should_skip_onedrive_root_entry "$_remote_file"; then
        printf '%s\n' "replica-bisync: [$_id] skipping inaccessible OneDrive root entry '$_remote_file'" >&2
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
    if should_skip_onedrive_root_entry "$_local_name"; then
      printf '%s\n' "replica-bisync: [$_id] skipping inaccessible OneDrive root entry '$_local_name'" >&2
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

  {
    printf '+ /RCLONE_TEST/\n'
    printf '+ /RCLONE_TEST/**\n'
    printf '%s\n' '- **'
  } >> "$_filter_file"

  rm -f "$_dir_entries_file" "$_file_entries_file"
  printf '%s\n' "$_filter_file"
}

# Remove macOS metadata artefacts from local replica roots so all hosts keep
# cloud trees clean even when files were introduced by a macOS client.
cleanup_local_macos_artifacts() {
  _target_dir="$1"

  if [ ! -d "$_target_dir" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-bisync: [dry-run] local metadata cleanup in $_target_dir"
    return 0
  fi

  for _pattern in $macos_metadata_file_globs; do
    find "$_target_dir" -type f -name "$_pattern" -delete
  done

  for _dir_name in $macos_metadata_dir_names; do
    find "$_target_dir" -type d -name "$_dir_name" -prune -exec rm -rf {} +
  done
}

# Remove macOS metadata artefacts from remotes to prevent cross-host churn.
# This runs before sync/bisync so stale metadata does not immediately get
# mirrored back to local replicas.
cleanup_remote_macos_artifacts() {
  _id="$1"
  _remote_ref="$2"
  _remote_path="$3"
  _provider="$4"
  _icloud_service="$5"
  _resolved_filters="$6"
  _runtime_filter_file="$7"

  shift 7

  if [ "$_provider" = "OneDrive" ] && [ "$_remote_path" = "/" ]; then
    # Upstream OneDrive API may expose Personal Vault in root listing and fail
    # all recursive traversals before filters are applied. Root cleanup here is
    # best-effort only, so skip it and rely on allowlist bisync filters to
    # prevent macOS metadata churn for reachable trees.
    printf '%s\n' "replica-bisync: [$_id] skipping remote macOS metadata cleanup at OneDrive root due to API invalidResourceId limitation" >&2
    return 0
  fi

  set -- --log-level ERROR --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s --max-duration 2m
  if [ "$_provider" = "iCloud" ]; then
    set -- "$@" --iclouddrive-service "$_icloud_service"
  fi
  if [ "$_provider" = "OneDrive" ]; then
    set -- "$@" --disable ListR
    set -- "$@" --filter "- Personal Vault" --filter "- Personal Vault/**"
    set -- "$@" --filter "- /Personal Vault" --filter "- /Personal Vault/**"
  fi
  if [ -n "$_resolved_filters" ]; then
    set -- "$@" --filter-from "$_resolved_filters"
  fi
  if [ -n "$_runtime_filter_file" ]; then
    set -- "$@" --filter-from "$_runtime_filter_file"
  fi

  set -- rclone delete "$_remote_ref" --rmdirs "$@"
  for _pattern in $macos_metadata_remote_filters; do
    set -- "$@" --filter "+ $_pattern"
  done
  set -- "$@" --filter "- **"

  if ! run_cmd "$@"; then
    printf '%s\n' "replica-bisync: [$_id] warning: failed to clean remote macOS metadata artefacts" >&2
    return 1
  fi

  return 0
}

run_bidirectional_sync() {
  _id="$1"
  _local_dir="$2"
  _remote_ref="$3"
  _state_marker="$4"
  shift 4

  run_bisync_with_lock_recovery() {
    if [ "$dry_run" = true ]; then
      run_cmd rclone bisync "$_local_dir" "$_remote_ref" "$@"
      return $?
    fi

    _preflight_running_pid="$(ps -axo pid=,args= | awk -v local="$_local_dir" -v remote="$_remote_ref" -v self="$$" '
      $1 != self && $2 == "rclone" && $3 == "bisync" {
        if (index($0, local) > 0 && index($0, remote) > 0) {
          print $1
          exit
        }
      }
    ' || true)"
    if [ -n "$_preflight_running_pid" ]; then
      printf '%s\n' "replica-bisync: [$_id] another bisync run is already active (PID $_preflight_running_pid); skipping this run without marking failure" >&2
      return 0
    fi

    _bisync_output_file="$(mktemp)"
    if rclone bisync "$_local_dir" "$_remote_ref" "$@" >"$_bisync_output_file" 2>&1; then
      cat "$_bisync_output_file"
      rm -f "$_bisync_output_file"
      return 0
    fi

    cat "$_bisync_output_file"

    if ! grep -Fq "prior lock file found:" "$_bisync_output_file"; then
      rm -f "$_bisync_output_file"
      return 1
    fi

    _running_pid="$(ps -axo pid=,args= | awk -v local="$_local_dir" -v remote="$_remote_ref" -v self="$$" '
      $1 != self && $2 == "rclone" && $3 == "bisync" {
        if (index($0, local) > 0 && index($0, remote) > 0) {
          print $1
          exit
        }
      }
    ' || true)"
    if [ -n "$_running_pid" ]; then
      printf '%s\n' "replica-bisync: [$_id] another bisync run is already active (PID $_running_pid); skipping this run without marking failure" >&2
      rm -f "$_bisync_output_file"
      return 0
    fi

    _lock_path="$(sed -n 's/.*prior lock file found:[[:space:]]*//p' "$_bisync_output_file" | head -n 1)"
    rm -f "$_bisync_output_file"

    if [ -z "$_lock_path" ] || [ ! -f "$_lock_path" ]; then
      printf '%s\n' "replica-bisync: [$_id] bisync lock contention detected but lock path is unavailable for stale-lock recovery" >&2
      return 1
    fi

    printf '%s\n' "replica-bisync: [$_id] clearing stale bisync lock at $_lock_path and retrying once" >&2
    if ! rclone deletefile "$_lock_path" \
      --log-level ERROR --retries 1 --low-level-retries 1 \
      --timeout 30s --contimeout 10s --max-duration 30s; then
      printf '%s\n' "replica-bisync: [$_id] failed to clear stale bisync lock at $_lock_path" >&2
      return 1
    fi

    rclone bisync "$_local_dir" "$_remote_ref" "$@"
  }

  _seeded=false
  if [ -f "$_state_marker" ]; then
    _seeded=true
  fi

  if [ "$_seeded" = true ]; then
    # Seeded: use --check-access for safety.
    if run_bisync_with_lock_recovery \
      --check-access --conflict-resolve newer --max-lock 2m \
      --timeout 60s --contimeout 15s --max-duration 2h \
      --retries 1 --low-level-retries 1 \
      --stats 30s --stats-one-line --stats-log-level NOTICE "$@"; then
      return 0
    fi

    # Seed marker indicates prior baseline files should exist. If a seeded run
    # fails, clear marker before recovery so subsequent invocations do not keep
    # re-entering the stale seeded path.
    if [ "$dry_run" = false ] && [ -f "$_state_marker" ]; then
      rm -f "$_state_marker"
    fi
    printf '%s\n' "replica-bisync: [$_id] seeded bisync check failed; cleared seed marker and retrying with recovery --resync" >&2
    printf '%s\n' "replica-bisync: [$_id] recovery --resync is running; do not start another run until this command completes" >&2
  fi

  # Seed run: --resync WITHOUT --check-access because rclone creates the
  # RCLONE_TEST access marker files during --resync; checking for them first
  # would fail.
  if run_bisync_with_lock_recovery \
    --resync --conflict-resolve newer --max-lock 2m \
    --timeout 60s --contimeout 15s --max-duration 2h \
    --retries 1 --low-level-retries 1 \
    --stats 30s --stats-one-line --stats-log-level NOTICE "$@"; then
    mkdir -p "$replica_state_dir"
    : > "$_state_marker"
    return 0
  fi

  return 1
}

# Keep macOS iCloudReplica mapped to the native CloudDocs path. This makes
# daily/scheduled replica-bisync runs self-healing even between full apply runs.
# Args:
#   $1 — iCloudReplica localPath relative to $HOME
ensure_macos_icloud_replica_symlink() {
  _relative_path="$1"
  _native_target="$HOME/Library/Mobile Documents"
  _replica_path="$HOME/$_relative_path"

  if [ ! -d "$_native_target" ]; then
    printf '%s\n' "replica-bisync: [iCloud] native target missing at $_native_target; cannot protect iCloudReplica symlink" >&2
    return 1
  fi

  if [ -L "$_replica_path" ]; then
    _current_target="$(readlink "$_replica_path")"
    if [ "$_current_target" = "$_native_target" ]; then
      return 0
    fi
    if [ "$dry_run" = true ]; then
      printf '%s\n' "replica-bisync: [dry-run] would update iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
      return 0
    fi
    rm "$_replica_path"
    ln -s "$_native_target" "$_replica_path"
    printf '%s\n' "replica-bisync: [iCloud] updated iCloudReplica symlink $_replica_path -> $_native_target (was $_current_target)"
    return 0
  fi

  if [ -e "$_replica_path" ]; then
    _backup_path="$_replica_path.pre-native-icloud.$(date +%Y%m%d%H%M%S)"
    if [ "$dry_run" = true ]; then
      printf '%s\n' "replica-bisync: [dry-run] would move $_replica_path to $_backup_path and create symlink -> $_native_target"
      return 0
    fi
    mv "$_replica_path" "$_backup_path"
    ln -s "$_native_target" "$_replica_path"
    printf '%s\n' "replica-bisync: [iCloud] migrated $_replica_path to native iCloud symlink target $_native_target (backup: $_backup_path)"
    return 0
  fi

  if [ "$dry_run" = true ]; then
    printf '%s\n' "replica-bisync: [dry-run] would create iCloudReplica symlink $_replica_path -> $_native_target"
    return 0
  fi

  ln -s "$_native_target" "$_replica_path"
  printf '%s\n' "replica-bisync: [iCloud] linked $_replica_path -> $_native_target"
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
replica_state_dir="$HOME/.config/nucleus/state/replica-bisync"

replica_lines_file="$(mktemp)"
printf '%s\n' "$replica_lines" > "$replica_lines_file"

# shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
while IFS="$(printf '\t')" read id direction local_path remote_name remote_path provider icloud_service filters_file; do
  if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
    continue
  fi

  # macOS iCloudReplica maps to native iCloud-managed storage semantics.
  # Skip the explicit rclone replica pass for this one entry to avoid
  # permission-denied churn while still allowing other replicas to converge.
  if [ "$current_os" = "Darwin" ] && [ "$provider" = "iCloud" ] && [ "$id" = "iCloud" ]; then
    if ! ensure_macos_icloud_replica_symlink "$local_path"; then
      failures=$((failures + 1))
    fi
    printf '%s\n' "replica-bisync: [$id] skipping on macOS (native iCloud handles sync)"
    continue
  fi

  local_dir="$HOME/$local_path"
  remote_ref="$remote_name:$remote_path"
  resolved_filters="$(resolve_filter_path "$filters_file")"
  runtime_filter_file=""
  state_marker="$replica_state_dir/$id.seeded"

  mkdir -p "$local_dir"

  if [ -n "$resolved_filters" ]; then
    if [ ! -f "$resolved_filters" ]; then
      printf '%s\n' "replica-bisync: filters file '$resolved_filters' not found for replica '$id'" >&2
      failures=$((failures + 1))
      continue
    fi
  fi

  cleanup_local_macos_artifacts "$local_dir"

  # Build shared rclone arguments once per replica so provider-specific safety
  # filters stay identical across pull/push/bisync code paths.
  set -- --log-level ERROR
  if [ "$provider" = "iCloud" ]; then
    set -- "$@" --iclouddrive-service "$icloud_service"
  fi
  if [ "$provider" = "OneDrive" ]; then
    # Microsoft currently exposes an inaccessible Personal Vault entry in some
    # root listings. Exclude rules alone are not reliable upstream, so for
    # root-level OneDrive replicas build an allowlist from accessible top-level
    # entries and sync only those.
    set -- "$@" --disable ListR
    if [ "$remote_path" = "/" ]; then
      runtime_filter_file="$(build_onedrive_root_filter_file "$id" "$local_dir" "$remote_ref")"
      if [ -n "$resolved_filters" ]; then
        set -- "$@" --filter-from "$resolved_filters"
      fi
      set -- "$@" --filter-from "$runtime_filter_file"
    elif [ -n "$resolved_filters" ]; then
      set -- "$@" --filter-from "$resolved_filters"
    fi
  else
    set -- "$@" --exclude ".DS_Store" --exclude ".DS_Store/**"
    set -- "$@" --exclude "._*" --exclude ".apdisk"
    set -- "$@" --exclude ".fseventsd/**" --exclude ".Spotlight-V100/**"
    set -- "$@" --exclude ".TemporaryItems/**" --exclude ".Trashes/**"
    if [ -n "$resolved_filters" ]; then
      set -- "$@" --filter-from "$resolved_filters"
    fi
  fi

  # Remote metadata cleanup is best-effort: some providers can reject specific
  # housekeeping traversals (for example protected OneDrive subtrees). Reuse
  # the same provider-aware filter inputs as the real sync path so cleanup does
  # not walk paths that the replica itself intentionally excludes.
  if ! cleanup_remote_macos_artifacts "$id" "$remote_ref" "$remote_path" "$provider" "$icloud_service" "$resolved_filters" "$runtime_filter_file"; then
    :
  fi

  case "$direction" in
    pull)
      printf '%s\n' "replica-bisync: [$id] pull $remote_ref -> $local_dir"
      if ! run_cmd rclone sync "$remote_ref" "$local_dir" "$@"; then
        failures=$((failures + 1))
      fi
      ;;
    push)
      printf '%s\n' "replica-bisync: [$id] push $local_dir -> $remote_ref"
      if ! run_cmd rclone sync "$local_dir" "$remote_ref" "$@"; then
        failures=$((failures + 1))
      fi
      ;;
    bidirectional)
      printf '%s\n' "replica-bisync: [$id] bisync $local_dir <-> $remote_ref"
      # Seeded runs use --check-access and auto-fallback to one --resync
      # retry on failure. This keeps day-2 operations safe while still
      # self-healing stale bisync state after local resets/interrupted runs.
      if ! run_bidirectional_sync "$id" "$local_dir" "$remote_ref" "$state_marker" "$@"; then
        printf '%s\n' "replica-bisync: [$id] bisync failed" >&2
        failures=$((failures + 1))
      fi
      ;;
    *)
      printf '%s\n' "replica-bisync: unsupported direction '$direction' for replica '$id'" >&2
      failures=$((failures + 1))
      ;;
  esac

  if [ -n "$runtime_filter_file" ] && [ -f "$runtime_filter_file" ]; then
    rm -f "$runtime_filter_file"
  fi
done < "$replica_lines_file"

rm -f "$replica_lines_file"

if [ "$failures" -gt 0 ]; then
  printf '%s\n' "replica-bisync: completed with $failures failure(s)" >&2
  exit 1
fi

printf '%s\n' "replica-bisync: completed successfully"
