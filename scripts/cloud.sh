#!/usr/bin/env bash
# Nucleus cloud management CLI.
#
# Subcommands:
#   setup   Verify/create rclone remotes, validate credentials, sync display
#           names from the user registry, and optionally run nucleus apply.
#   reset   Remove local replica data and rclone cache directories so the next
#           sync starts from a clean local state (local-only; never touches
#           remote data).
#   sync    Pull-only replica sync (remote -> local) for every enabled replica
#           declared in src/users/ for the current user.
#
# Usage: nucleus-cloud <setup|reset|sync> [options]
#
# Prerequisites: rclone and jq on PATH, and the repo checkout with src/users/.

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
# shellcheck source=../src/scripts/lib/lib.sh
. "$SCRIPT_DIR/../src/scripts/lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "setup|reset|sync [options]"
  cat <<'EOF'
  setup    Verify/create rclone remotes, validate credentials, sync display
           names, and optionally run nucleus apply.
  reset    Remove local replica data and rclone cache (local-only).
  sync     Pull-only replica sync (remote -> local).

  setup options:
    --apply|--no-apply  Run nucleus apply to converge cloud mount services
                         (default: --no-apply).

  reset options:
    --dry-run           Print planned removals instead of executing them.
    --replica-id ID     Reset only the replica with the given id.
    --repo-root PATH    Repo checkout used to find src/users/.

  sync options:
    --dry-run           Print planned sync commands instead of executing them.
    --replica-id ID     Sync only the replica with the given id.
    --repo-root PATH    Repo checkout used to find src/users/.

  Common options:
    -h|--help           Show usage.
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ──────────────────────────────────────────────────────────────────────────────

# Reads the configured iCloud service for a remote from the assembled user registry.
# Args: $1 — repo root; $2 — remote name; $3 — assembled user registry JSON.
# Output: `drive` or `photos`.
resolve_icloud_service_for_remote() {
  _ics_repo_root="$1"
  _ics_remote_name="$2"
  _ics_registry="$3"

  if [ -z "$_ics_registry" ] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'drive'
    return 0
  fi

  _ics_username="$(id -un)"
  _ics_services="$({
    jq -r \
      --arg username "$_ics_username" \
      --arg remote "$_ics_remote_name" \
      '
        [
          ((.[$username].cloudDrives.mounts // [])[]?),
          ((.[$username].cloudDrives.replicas // [])[]?)
        ]
        | map(select(.provider == "iCloud" and .remoteName == $remote) | (.iCloudService // "drive"))
        | unique
        | .[]
      ' \
      <<<"$_ics_registry"
  } 2>/dev/null)"

  _ics_service_count="$(printf '%s\n' "$_ics_services" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  case "$_ics_service_count" in
  1)
    printf '%s\n' "$_ics_services" | /usr/bin/awk 'NF { print; exit }'
    ;;
  [2-9]* | [1-9][0-9]*)
    warn "multiple iCloud services are configured for remote '$_ics_remote_name'; defaulting remote setup to 'drive' and letting mount commands override per entry."
    printf '%s\n' 'drive'
    ;;
  *)
    printf '%s\n' 'drive'
    ;;
  esac
}

collect_missing_remotes() {
  _required="$1"

  if ! _listed="$(rclone listremotes 2>/dev/null)"; then
    return 1
  fi

  _missing=""
  for _remote in $_required; do
    if ! printf '%s\n' "$_listed" | grep -Fxq "${_remote}:"; then
      if [ -z "$_missing" ]; then
        _missing="$_remote"
      else
        _missing="$_missing $_remote"
      fi
    fi
  done

  printf '%s\n' "$_missing"
}

# Collect enabled mount service IDs from the user registry for this user.
collect_configured_mount_service_ids() {
  _ccmsi_registry="$1"

  if [ -z "$_ccmsi_registry" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  _ccmsi_username="$(id -un)"
  { jq -r \
    --arg username "$_ccmsi_username" \
    '
      ((.[$username].cloudDrives.mounts // [])[]?)
      | select((.enable // true) == true and .id != null and .remoteName != null)
      | [.id, .remoteName]
      | @tsv
    ' \
    <<<"$_ccmsi_registry"; } 2>/dev/null || true # check-suppress:suppression_doc: user registry may be empty or malformed; empty result is handled.
}

# Restart managed cloud mount services so refreshed remote descriptions and
# credentials are reflected immediately in mounted volumes.
restart_cloud_mount_services() {
  _rcms_registry="$1"
  _rcms_mount_rows="$(collect_configured_mount_service_ids "$_rcms_registry")"
  if [ -z "$_rcms_mount_rows" ]; then
    return 0
  fi

  case "$(uname)" in
  Darwin)
    _rcms_uid="$(id -u)"
    say "restarting managed macOS cloud mount services..."

    while IFS="$(printf '\t')" read -r mount_id remote_name; do
      if [ -z "$mount_id" ]; then
        continue
      fi

      # iCloud mount restart can block for an extended period while Apple
      # auth/session state reconciles. Skip it here so cloud-setup remains
      # responsive; users can still restart iCloud mounts via nucleus apply.
      if [ "$remote_name" = "iCloud" ]; then
        say "skipping launchctl restart for iCloud mount (${mount_id}); restart via nucleus apply if needed."
        continue
      fi

      _rcms_label="local.cloud-mount.${mount_id}"
      _rcms_target="gui/${_rcms_uid}/${_rcms_label}"

      # Both missing-service and launchctl parse failures are benign here;
      # if the service is absent we emit a targeted hint and continue.
      if launchctl print "$_rcms_target" >/dev/null 2>&1; then
        if launchctl kickstart -k "$_rcms_target"; then
          say "restarted $_rcms_label (${remote_name})"
        else
          warn "failed to restart $_rcms_label (${remote_name}); run nucleus apply if mount content remains stale."
        fi
      else
        warn "mount service $_rcms_label (${remote_name}) is not loaded; run nucleus apply to create/load it."
      fi
    done <<EOF
$_rcms_mount_rows
EOF
    ;;
  Linux)
    if ! command -v systemctl >/dev/null 2>&1; then
      warn "systemctl not found; cannot restart user cloud mount services on Linux."
      return 0
    fi

    say "restarting managed Linux cloud mount services..."

    while IFS="$(printf '\t')" read -r mount_id remote_name; do
      if [ -z "$mount_id" ]; then
        continue
      fi

      _rcms_service="cloud-mount-${mount_id}.service"
      if systemctl --user is-active --quiet "$_rcms_service" || systemctl --user is-enabled --quiet "$_rcms_service"; then
        if systemctl --user restart "$_rcms_service"; then
          say "restarted $_rcms_service (${remote_name})"
        else
          warn "failed to restart $_rcms_service (${remote_name}); run nucleus apply if mount content remains stale."
        fi
      else
        warn "mount service $_rcms_service (${remote_name}) is not installed/enabled; run nucleus apply to create/load it."
      fi
    done <<EOF
$_rcms_mount_rows
EOF
    ;;
  *)
    return 0
    ;;
  esac
}

# Maps a known remote name to its rclone provider type string.
remote_provider_type() {
  case "$1" in
  GoogleDrive) printf 'drive' ;;
  iCloud) printf 'iclouddrive' ;;
  OneDrive) printf 'onedrive' ;;
  *) printf '' ;;
  esac
}

# Selects backend-specific create arguments.
# Args: $1 — rclone provider type; $2 — remote name; $3 — repo root.
remote_provider_create_args() {
  _rpca_provider_type="$1"
  _rpca_remote_name="$2"
  _rpca_repo_root="$3"

  case "$_rpca_provider_type" in
  drive)
    printf '%s\n' 'acknowledge_abuse' 'true'
    ;;
  iclouddrive)
    _rpca_service="$(resolve_icloud_service_for_remote "$_rpca_repo_root" "$_rpca_remote_name" "${USERS_REGISTRY:-}")"
    printf '%s\n' 'service' "$_rpca_service" '--all'
    ;;
  *) return 0 ;;
  esac
}

# run_local_cmd — Execute a destructive command, honoring --dry-run.
run_local_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "would run: $*"
    return 0
  fi
  "$@"
}

_load_users_registry() {
  "$REPO_ROOT/src/scripts/lib/load-user-registry.sh" \
    --host "$(resolve_nucleus_host)" \
    --repo-root "$REPO_ROOT"
}

# load_provider_gc_entries PROVIDER FIELD
#   Reads a GC-config field (files|dirs|remoteExcludes|blockedRoots) for a
#   provider from the user registry cloudDrives.replicaGc domain.
load_provider_gc_entries() {
  _provider="$1"
  _field="$2"

  echo "$USERS_REGISTRY" | jq -r --arg username "$username" --arg provider "$_provider" --arg field "$_field" '
    ((.[$username].cloudDrives.replicaGc // {})[$provider] // {})[$field] // []
    | .[]
  '
}

# run_cmd — Executes a command, or prints it under --dry-run.
run_cmd() {
  if [ "$dry_run" = true ]; then
    dry_run "would run: $*"
    return 0
  fi
  "$@"
}

# record_unique_name LIST_FILE NAME
#   Appends NAME to LIST_FILE once.
record_unique_name() {
  _list_file="$1"
  _name="$2"

  if [ -z "$_name" ]; then
    return 0
  fi

  if [ ! -f "$_list_file" ] || ! grep -Fxq "$_name" "$_list_file"; then
    printf '%s\n' "$_name" >>"$_list_file"
  fi
}

# remote_top_level_path_accessible REMOTE_REF ENTRY_NAME
#   Probes whether a top-level remote entry can actually be listed.
remote_top_level_path_accessible() {
  _remote_ref="$1"
  _entry_name="$2"

  _probe_remote_ref="${_remote_ref%/}/$_entry_name"

  rclone lsf "$_probe_remote_ref" \
    --max-depth 1 --disable ListR --log-level ERROR \
    --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s \
    --max-duration 1m >/dev/null 2>&1
}

# should_skip_onedrive_root_entry ENTRY_NAME BLOCKED_ROOT_ENTRIES
#   Returns 0 when ENTRY_NAME must not be synced.
should_skip_onedrive_root_entry() {
  _entry_name="$1"
  _blocked_root_entries="$2"
  _entry_lc="$(printf '%s' "$_entry_name" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$_blocked_root_entries" ]; then
    return 1
  fi

  printf '%s\n' "$_blocked_root_entries" | grep -Fxq "$_entry_lc"
}

# build_onedrive_root_filter_file ID LOCAL_DIR REMOTE_REF REMOTE_EXCLUDES BLOCKED_ROOT_ENTRIES
#   Builds a runtime rclone filter file restricting the pull to top-level
#   entries that are present and actually accessible.
build_onedrive_root_filter_file() {
  _id="$1"
  _local_dir="$2"
  _remote_ref="$3"
  _remote_excludes="$4"
  _blocked_root_entries="$5"

  _filter_file="$(mktemp)"
  _dir_entries_file="$(mktemp)"
  _file_entries_file="$(mktemp)"

  : >"$_filter_file"
  for _pattern in $_remote_excludes; do
    printf -- '- %s\n' "$_pattern" >>"$_filter_file"
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
      printf '+ /%s/\n' "$_dir_name" >>"$_filter_file"
      printf '+ /%s/**\n' "$_dir_name" >>"$_filter_file"
    done <"$_dir_entries_file"
  fi

  if [ -f "$_file_entries_file" ]; then
    while IFS= read -r _file_name; do
      if [ -z "$_file_name" ]; then
        continue
      fi
      printf '+ /%s\n' "$_file_name" >>"$_filter_file"
    done <"$_file_entries_file"
  fi

  # The trailing catch-all exclude makes the filter closed-world.
  printf '%s\n' '- **' >>"$_filter_file"

  rm -f "$_dir_entries_file" "$_file_entries_file"
  printf '%s\n' "$_filter_file"
}

# gc_local_macos_artifacts TARGET_DIR FILE_GLOBS DIR_NAMES
#   Deletes macOS metadata artifacts from a replica tree after sync.
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

# ensure_macos_icloud_replica_symlink RELATIVE_PATH
#   Make ~/RELATIVE_PATH a symlink to ~/Library/Mobile Documents.
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
    error "[iCloud] $_replica_path must symlink to $_native_target (found $_current_target); fix manually and re-run sync"
    return 1
  fi

  if [ -e "$_replica_path" ]; then
    error "[iCloud] $_replica_path exists and is not the native iCloud symlink; fix manually and re-run sync"
    return 1
  fi

  if [ "$dry_run" = true ]; then
    dry_run "would create iCloudReplica symlink $_replica_path -> $_native_target"
    return 0
  fi

  ln -s "$_native_target" "$_replica_path"
  say "[iCloud] linked $_replica_path -> $_native_target"
}

# resolve_filter_path CANDIDATE
#   Expands a filters-file path from users.json into an absolute path.
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

# set_replica_tree_writable TARGET_DIR
#   Temporarily grant owner write access for convergence.
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

# ──────────────────────────────────────────────────────────────────────────────
# setup subcommand — verify/create rclone remotes, validate credentials, sync
# display names, and optionally run nucleus apply.
# ──────────────────────────────────────────────────────────────────────────────

do_setup() {
  apply=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --apply)
      apply=true
      ;;
    --no-apply)
      apply=false
      ;;
    *)
      error "unsupported argument '$1'"
      usage >&2
      exit 1
      ;;
    esac
    shift
  done

  if ! command -v rclone >/dev/null 2>&1; then
    error "rclone not found on PATH. Run apply/bootstrap first, then retry."
  fi

  repo_root="$(derive_repo_root)"

  if [ -d "$repo_root/src/users" ] && command -v jq >/dev/null 2>&1; then
    USERS_REGISTRY="$("$repo_root/src/scripts/lib/load-user-registry.sh" --host "$(resolve_nucleus_host)" --repo-root "$repo_root")"
  else
    USERS_REGISTRY=""
  fi

  required_remotes="GoogleDrive iCloud OneDrive"
  missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
    error "failed to read rclone remotes. Run 'rclone config' manually and retry."
  }

  if [ -n "$missing_remotes" ]; then
    # Inject rclone config passphrase from materialized SOPS secret so the remote
    # creation flow inherits it and rclone encrypts the new config entry with the
    # managed passphrase automatically.
    _rclone_pass_file="$NUCLEUS_USER_ROOT/secrets/rclone-config-pass"
    if [ -s "$_rclone_pass_file" ]; then
      RCLONE_CONFIG_PASS="$(cat "$_rclone_pass_file")"
      export RCLONE_CONFIG_PASS
    fi
    say "missing rclone remotes: $missing_remotes"
    say "creating and authenticating each missing remote..."
    for _remote in $missing_remotes; do
      _type="$(remote_provider_type "$_remote")"
      if [ -z "$_type" ]; then
        warn "unknown remote '$_remote'; add it manually with 'rclone config'."
        continue
      fi
      _create_args="$(remote_provider_create_args "$_type" "$_remote" "$repo_root")"
      say "setting up remote '$_remote' (provider: $_type)..."
      if [ -n "$_create_args" ]; then
        # Word splitting is intentional here: helper output is a whitespace-
        # separated flag list for rclone, not arbitrary user input.
        # shellcheck disable=SC2086 # reason: word splitting intentional for rclone flag passthrough
        rclone config create "$_remote" "$_type" $_create_args
      else
        rclone config create "$_remote" "$_type"
      fi
    done

    missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
      error "failed to re-read rclone remotes after setup."
    }
  fi

  if [ -n "$missing_remotes" ]; then
    error "required remotes are still missing: $missing_remotes"
    error "rerun this command after completing those remotes in rclone config."
  fi

  say "required remotes are configured."

  # Validate each remote's credentials; recreate any remote that fails so stale
  # auth tokens can be refreshed without manually deleting and rebuilding the
  # config.
  say "validating remote credentials with root-only listings..."
  _stale_remotes=""
  for _remote in $required_remotes; do
    if rclone lsd "$_remote:" >/dev/null 2>&1; then
      say "✓ $_remote credentials valid"
    else
      warn "✗ $_remote credentials stale or unreachable; will recreate..."
      _stale_remotes="${_stale_remotes:+$_stale_remotes }$_remote"
    fi
  done

  if [ -n "$_stale_remotes" ]; then
    _rclone_pass_file="$NUCLEUS_USER_ROOT/secrets/rclone-config-pass"
    if [ -s "$_rclone_pass_file" ]; then
      RCLONE_CONFIG_PASS="$(cat "$_rclone_pass_file")"
      export RCLONE_CONFIG_PASS
    fi
    for _remote in $_stale_remotes; do
      say "deleting and recreating remote '$_remote'..."
      if ! rclone config delete "$_remote"; then
        warn "could not delete '$_remote' config entry; continuing."
      fi
      _type="$(remote_provider_type "$_remote")"
      _create_args="$(remote_provider_create_args "$_type" "$_remote" "$repo_root")"
      if [ -n "$_create_args" ]; then
        # shellcheck disable=SC2086 # reason: word splitting intentional for rclone flag passthrough
        rclone config create "$_remote" "$_type" $_create_args
      else
        rclone config create "$_remote" "$_type"
      fi
    done

    say "re-validating credentials after recreation..."
    _validation_failed=false
    for _remote in $_stale_remotes; do
      if rclone lsd "$_remote:" >/dev/null 2>&1; then
        say "✓ $_remote credentials valid"
      else
        warn "✗ $_remote credentials still invalid after recreation"
        _validation_failed=true
      fi
    done

    if [ "$_validation_failed" = true ]; then
      error "credential validation failed after recreation; recheck in 'rclone config'."
    fi
  fi

  say "all credentials valid."

  # Acknowledge Google Drive abuse flag so rclone can download flagged files.
  if rclone listremotes | grep -Fxq 'GoogleDrive:'; then
    _current_abuse="$({
      rclone config dump | jq -r '.GoogleDrive.acknowledge_abuse // "false"'
    } 2>/dev/null || true)" # check-suppress:suppression_doc: token/URL may not be resolvable; best-effort extraction with downstream guards.
    if [ "$_current_abuse" != "true" ]; then
      if rclone config update GoogleDrive acknowledge_abuse true; then
        say "enabled acknowledge_abuse on GoogleDrive"
      else
        warn "failed to enable acknowledge_abuse on GoogleDrive"
      fi
    fi
  fi

  # Sync display names from the user registry to rclone config descriptions.
  if [ -n "$USERS_REGISTRY" ] && command -v jq >/dev/null 2>&1; then
    say "syncing display names from user registry to rclone config..."
    _username="$(id -un)"
    _display_names="$({
      jq -r \
        --arg username "$_username" \
        '
          [
            ((.[$username].cloudDrives.mounts // [])[]?),
            ((.[$username].cloudDrives.replicas // [])[]?)
          ]
          | unique_by(.remoteName)
          | .[]
          | select(.name != null and .remoteName != null)
          | [.remoteName, .name]
          | @tsv
        ' \
        <<<"$USERS_REGISTRY"
      # check-suppress:suppression_doc: token/URL may not be resolvable; best-effort extraction with downstream guards.
    } 2>/dev/null || true)"

    if [ -n "$_display_names" ]; then
      while IFS="$(printf '\t')" read -r remote_name display_name; do
        if [ -z "$remote_name" ] || [ -z "$display_name" ]; then
          continue
        fi

        if ! rclone listremotes | grep -Fxq "${remote_name}:"; then
          continue
        fi

        # Skip no-op updates to avoid unnecessary provider re-auth prompts.
        _current_description="$({
          rclone config dump | jq -r --arg remote "$remote_name" '.[$remote].description // empty'
        } 2>/dev/null || true)" # check-suppress:suppression_doc: token/URL may not be resolvable; best-effort extraction with downstream guards.
        if [ "$_current_description" = "$display_name" ]; then
          continue
        fi

        if rclone config update "$remote_name" description "$display_name"; then
          say "updated $remote_name description to '$display_name'"
        else
          warn "failed to update $remote_name description; continuing with mount restart."
        fi
      done <<EOF
$_display_names
EOF
    fi
  fi

  if [ -n "$USERS_REGISTRY" ]; then
    restart_cloud_mount_services "$USERS_REGISTRY"
  fi

  if [ "$apply" = true ]; then
    say "running nucleus apply to converge cloud mount services..."
    nix --option warn-dirty false run "$repo_root/src#apply"
  fi

  say "setup complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# reset subcommand — remove local replica data and rclone cache (local-only).
# ──────────────────────────────────────────────────────────────────────────────

do_reset() {
  dry_run=false
  replica_id_filter=""

  # Flags are parsed strictly — unknown arguments abort so a typo can never
  # silently reset the wrong replica set.
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
    -h | --help)
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

  USERS_REGISTRY_ROOT="$REPO_ROOT/src/users"

  if [ ! -d "$USERS_REGISTRY_ROOT" ]; then
    error "users registry root not found at $USERS_REGISTRY_ROOT"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse user registry"
  fi

  USERS_REGISTRY="$(_load_users_registry)"

  username="$(id -un)"
  host="$(resolve_nucleus_host)"
  # The query filters to enabled replicas that name a remote — a replica
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
    ' <<<"$USERS_REGISTRY"
  } || true)" # check-suppress:suppression_doc: jq query may fail if user registry is missing; empty result handled by [ -z ] check downstream.

  if [ -z "$replica_lines" ]; then
    say "no enabled replicas for user '$username'"
    exit 0
  fi

  local_failures=0

  # The replica list is materialized to a temp file so the loop below can read
  # from a stable fd while its body runs commands that also consume stdin.
  replica_lines_file="$(mktemp)"
  printf '%s\n' "$replica_lines" >"$replica_lines_file"

  while IFS="$(printf '\t')" read -r id local_path provider icloud_service; do
    if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
      continue
    fi

    local_root="$HOME/$local_path"

    # macOS iCloud Drive replicas are represented as symlinks to the native
    # CloudDocs path. Never recurse into that target during reset; only remove
    # the symlink itself so remotes and native-managed content remain untouched.
    if [ "$host" = "MacBook" ] && [ "$provider" = "iCloud" ] && [ "$icloud_service" = "drive" ]; then
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
    if [ -e "$local_root" ] || [ -L "$local_root" ]; then
      # A previous sync can leave the tree read-only; u+w is restored before rm
      # so removal succeeds. Failure is tolerated (may be symlink/already writable).
      if ! run_local_cmd chmod -R u+w "$local_root" 2>/dev/null; then
        : # Ignore chmod errors (may be symlink or already writable)
      fi
      if ! run_local_cmd rm -rf -- "$local_root"; then
        local_failures=$((local_failures + 1))
        continue
      fi
    fi
  done <"$replica_lines_file"

  rm -f "$replica_lines_file"

  # Reset rclone's local cache directories to clear stale sync state.
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
}

# ──────────────────────────────────────────────────────────────────────────────
# sync subcommand — pull-only replica sync (remote -> local).
# ──────────────────────────────────────────────────────────────────────────────

do_sync() {
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
    -h | --help)
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

  USERS_REGISTRY_ROOT="$REPO_ROOT/src/users"

  if [ ! -d "$USERS_REGISTRY_ROOT" ]; then
    error "users registry root not found at $USERS_REGISTRY_ROOT"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error "jq not found; cannot parse user registry"
  fi

  USERS_REGISTRY="$(_load_users_registry)"

  # rclone configs may be pass-encrypted; RCLONE_CONFIG_PASS lets rclone
  # decrypt them at runtime. The pass file is only exported when present, so
  # the environment stays clean on machines without encrypted remotes.
  rclone_pass_path="$NUCLEUS_USER_ROOT/secrets/rclone-config-pass"
  if [ -s "$rclone_pass_path" ]; then
    rclone_config_pass_value="$(cat "$rclone_pass_path")"
    export RCLONE_CONFIG_PASS="$rclone_config_pass_value"
  fi

  username="$(id -un)"
  host="$(resolve_nucleus_host)"

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
          (.name // .id)
        ]
      | @tsv
    ' <<<"$USERS_REGISTRY"
  } || true)" # check-suppress:suppression_doc: jq query may fail if user registry is missing; empty result handled by [ -z ] check downstream.

  if [ -z "$replica_lines" ]; then
    say "no enabled replicas for user '$username'"
    exit 0
  fi

  failures=0

  replica_lines_file="$(mktemp)"
  printf '%s\n' "$replica_lines" >"$replica_lines_file"

  # The replica list is staged in a temp file so the loop reads from a real file
  # descriptor — a pipeline would run the loop body in a subshell and lose the
  # failures counter.
  while IFS="$(printf '\t')" read -r id direction local_path remote_path provider icloud_service filters_file read_write display_name; do
    if [ -n "$replica_id_filter" ] && [ "$id" != "$replica_id_filter" ]; then
      continue
    fi

    # Native iCloud already syncs this tree (via the replica symlink).
    if [ "$host" = "MacBook" ] && [ "$provider" = "iCloud" ] && [ "$id" = "iCloud" ]; then
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

    # Replicas are pull-only by policy — a push would overwrite cloud state.
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

    # A missing filters file is a hard failure for read-only replicas.
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

    # Default rclone log level is INFO; ERROR keeps successful syncs quiet.
    set -- --log-level ERROR
    if [ "$provider" = "iCloud" ]; then
      set -- "$@" --iclouddrive-service "$icloud_service"
    fi
    if [ "$provider" = "OneDrive" ]; then
      if [ "$remote_path" = "/" ]; then
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

    # Restore the read-only invariant after the run so replica trees are
    # protected between runs.
    if [ "$read_write" != "true" ]; then
      if ! set_replica_tree_read_only "$local_dir"; then
        warn "[$display_name] failed to lock replica tree '$local_dir'"
        failures=$((failures + 1))
      fi
    fi
  done <"$replica_lines_file"

  rm -f "$replica_lines_file"

  if [ "$failures" -gt 0 ]; then
    error "completed with $failures failure(s)"
    exit 1
  fi

  say "completed successfully"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main dispatch
# ──────────────────────────────────────────────────────────────────────────────

action="${1:-help}"
case "$action" in
-h | --help | help)
  usage
  exit 0
  ;;
esac
shift 2>/dev/null || true # check-suppress:suppression_doc: shift fails when no args remain (subcommand-only invocation); ignored intentionally

case "$action" in
setup) do_setup "$@" ;;
reset) do_reset "$@" ;;
sync) do_sync "$@" ;;
*)
  error "unsupported subcommand '$action'"
  usage >&2
  exit 1
  ;;
esac
