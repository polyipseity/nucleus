#!/usr/bin/env sh
# Guides one-time cloud remote setup and validates cloud mount automation.
#
# Operations:
#   1. verify required rclone remotes exist (GoogleDrive, iCloud, OneDrive)
#   2. if any are missing, create each with the correct provider type and
#      repo-configured backend defaults, then prompt for authentication
#      (no manual menu navigation required)
#   3. validate each remote's credentials work (via rclone lsd)
#   4. optionally run nucleus apply if --apply flag provided
#
# Arguments:
#   --apply       run nucleus apply to converge cloud mount services
#                 (default: setup/validate only; user can run nucleus apply later)
#
# Exit conditions:
#   0 on success; non-zero when required remotes are still missing or credential
#   validation fails after a recreation attempt.

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
  # Stderr suppressed: git failure outside a repository is expected and benign;
  # the exit code is checked via the conditional.
  if _rnr_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$_rnr_git_root"
    return 0
  fi
  printf '%s\n' "$HOME/dev/nucleus"
}

# Reads the configured iCloud service for a remote from src/modules/users.json.
# Args: $1 — repo root; $2 — remote name.
# Output: `drive` or `photos`.
# WHY: `rclone config create ... iclouddrive --all` asks which Apple service to
# use. The repository already declares per-user cloud-drive intent, so use that
# as the source of truth and skip the extra prompt.
resolve_icloud_service_for_remote() {
  _ics_repo_root="$1"
  _ics_remote_name="$2"
  _ics_users_json="$_ics_repo_root/src/modules/users.json"

  if [ ! -f "$_ics_users_json" ] || ! command -v jq >/dev/null 2>&1; then
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
      "$_ics_users_json"
  } 2>/dev/null)"

  _ics_service_count="$(printf '%s\n' "$_ics_services" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  case "$_ics_service_count" in
    1)
      printf '%s\n' "$_ics_services" | /usr/bin/awk 'NF { print; exit }'
      ;;
    [2-9]*|[1-9][0-9]*)
      printf '%s\n' "cloud-setup: multiple iCloud services are configured for remote '$_ics_remote_name'; defaulting remote setup to 'drive' and letting mount commands override per entry." >&2
      printf '%s\n' 'drive'
      ;;
    *)
      printf '%s\n' 'drive'
      ;;
  esac
}

collect_missing_remotes() {
  _required="$1"

  # Stderr suppressed: when rclone has no config yet, listremotes may print
  # expected setup hints; we only need the parsed remote names here and branch
  # on the command exit code below.
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

# Collect enabled mount service IDs from src/modules/users.json for this user.
# Args: $1 — absolute users.json path.
# Output: tab-separated rows: <mount id> <remoteName>
collect_configured_mount_service_ids() {
  _ccmsi_users_json="$1"

  if [ ! -f "$_ccmsi_users_json" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  _ccmsi_username="$(id -un)"
  jq -r \
    --arg username "$_ccmsi_username" \
    '
      ((.[$username].cloudDrives.mounts // [])[]?)
      | select((.enable // true) == true and .id != null and .remoteName != null)
      | [.id, .remoteName]
      | @tsv
    ' \
    "$_ccmsi_users_json" 2>/dev/null || true
}

# Restart managed cloud mount services so refreshed remote descriptions and
# credentials are reflected immediately in mounted volumes.
# Args: $1 — absolute users.json path.
restart_cloud_mount_services() {
  _rcms_users_json="$1"
  _rcms_mount_rows="$(collect_configured_mount_service_ids "$_rcms_users_json")"
  if [ -z "$_rcms_mount_rows" ]; then
    return 0
  fi

  case "$(uname)" in
    Darwin)
      _rcms_uid="$(id -u)"
      printf '%s\n' "cloud-setup: restarting managed macOS cloud mount services..."

      # shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
      while IFS="$(printf '\t')" read mount_id remote_name; do
        if [ -z "$mount_id" ]; then
          continue
        fi

        # iCloud mount restart can block for an extended period while Apple
        # auth/session state reconciles. Skip it here so cloud-setup remains
        # responsive; users can still restart iCloud mounts via nucleus apply.
        if [ "$remote_name" = "iCloud" ]; then
          printf '%s\n' "cloud-setup: skipping launchctl restart for iCloud mount (${mount_id}); restart via nucleus apply if needed."
          continue
        fi

        _rcms_label="local.cloud-mount.${mount_id}"
        _rcms_target="gui/${_rcms_uid}/${_rcms_label}"

        # Both missing-service and launchctl parse failures are benign here;
        # if the service is absent we emit a targeted hint and continue.
        if launchctl print "$_rcms_target" >/dev/null 2>&1; then
          if launchctl kickstart -k "$_rcms_target"; then
            printf '%s\n' "cloud-setup: restarted $_rcms_label (${remote_name})"
          else
            printf '%s\n' "cloud-setup: warning: failed to restart $_rcms_label (${remote_name}); run nucleus apply if mount content remains stale." >&2
          fi
        else
          printf '%s\n' "cloud-setup: mount service $_rcms_label (${remote_name}) is not loaded; run nucleus apply to create/load it." >&2
        fi
      done <<EOF
$_rcms_mount_rows
EOF
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' "cloud-setup: warning: systemctl not found; cannot restart user cloud mount services on Linux." >&2
        return 0
      fi

      printf '%s\n' "cloud-setup: restarting managed Linux cloud mount services..."

      # shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
      while IFS="$(printf '\t')" read mount_id remote_name; do
        if [ -z "$mount_id" ]; then
          continue
        fi

        _rcms_service="cloud-mount-${mount_id}.service"
        if systemctl --user is-active --quiet "$_rcms_service" || systemctl --user is-enabled --quiet "$_rcms_service"; then
          if systemctl --user restart "$_rcms_service"; then
            printf '%s\n' "cloud-setup: restarted $_rcms_service (${remote_name})"
          else
            printf '%s\n' "cloud-setup: warning: failed to restart $_rcms_service (${remote_name}); run nucleus apply if mount content remains stale." >&2
          fi
        else
          printf '%s\n' "cloud-setup: mount service $_rcms_service (${remote_name}) is not installed/enabled; run nucleus apply to create/load it." >&2
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

skip_apply=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      skip_apply=false
      ;;
    *)
      printf '%s\n' "cloud-setup: unsupported argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

# Maps a known remote name to its rclone provider type string.
remote_provider_type() {
  case "$1" in
    GoogleDrive) printf 'drive' ;;
    iCloud)      printf 'iclouddrive' ;;
    OneDrive)    printf 'onedrive' ;;
    *)           printf '' ;;
  esac
}

# Selects backend-specific create arguments.
# Args: $1 — rclone provider type; $2 — remote name; $3 — repo root.
# Output: zero or more CLI args to append to `rclone config create`.
# WHY: `rclone config create` silently takes defaults for unanswered options.
# The iCloud backend has required fields like `apple_id` and `password` (the
# Apple account password) with no safe default, so `--all` is required to
# force the full interactive question flow. The iCloud service choice is
# passed explicitly so rclone skips the drive-vs-photos question.
remote_provider_create_args() {
  _rpca_provider_type="$1"
  _rpca_remote_name="$2"
  _rpca_repo_root="$3"

  case "$_rpca_provider_type" in
    iclouddrive)
      _rpca_service="$(resolve_icloud_service_for_remote "$_rpca_repo_root" "$_rpca_remote_name")"
      printf '%s\n' 'service' "$_rpca_service" '--all'
      ;;
    *)           return 0 ;;
  esac
}

if ! command -v rclone >/dev/null 2>&1; then
  printf '%s\n' "cloud-setup: rclone not found on PATH. Run apply/bootstrap first, then retry." >&2
  exit 1
fi

repo_root="$(resolve_nucleus_root)"
USERS_JSON="$repo_root/src/modules/users.json"

required_remotes="GoogleDrive iCloud OneDrive"
missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
  printf '%s\n' "cloud-setup: failed to read rclone remotes. Run 'rclone config' manually and retry." >&2
  exit 1
}

if [ -n "$missing_remotes" ]; then
  # Inject rclone config passphrase from materialized SOPS secret so the remote
  # creation flow inherits it and rclone encrypts the new config entry with the
  # managed passphrase automatically.
  # WHY conditional: secret file may be absent on first bootstrap before sops-nix
  # has materialized it; benign absence — rclone uses an unencrypted config.
  _rclone_pass_file="$HOME/.config/nucleus/secrets/rclone-config-pass"
  if [ -s "$_rclone_pass_file" ]; then
    RCLONE_CONFIG_PASS="$(cat "$_rclone_pass_file")"
    export RCLONE_CONFIG_PASS
  fi
  printf '%s\n' "cloud-setup: missing rclone remotes: $missing_remotes"
  printf '%s\n' "cloud-setup: creating and authenticating each missing remote..."
  for _remote in $missing_remotes; do
    _type="$(remote_provider_type "$_remote")"
    if [ -z "$_type" ]; then
      printf '%s\n' "cloud-setup: unknown remote '$_remote'; add it manually with 'rclone config'." >&2
      continue
    fi
    _create_args="$(remote_provider_create_args "$_type" "$_remote" "$repo_root")"
    printf '%s\n' "cloud-setup: setting up remote '$_remote' (provider: $_type)..."
    if [ -n "$_create_args" ]; then
      # Word splitting is intentional here: helper output is a whitespace-
      # separated flag list for rclone, not arbitrary user input.
      # shellcheck disable=SC2086
      rclone config create "$_remote" "$_type" $_create_args
    else
      rclone config create "$_remote" "$_type"
    fi
  done

  missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
    printf '%s\n' "cloud-setup: failed to re-read rclone remotes after setup." >&2
    exit 1
  }
fi

if [ -n "$missing_remotes" ]; then
  printf '%s\n' "cloud-setup: required remotes are still missing: $missing_remotes" >&2
  printf '%s\n' "cloud-setup: rerun this command after completing those remotes in rclone config." >&2
  exit 1
fi

printf '%s\n' "cloud-setup: required remotes are configured."

# Validate each remote's credentials; recreate any remote that fails so stale
# auth tokens can be refreshed without manually deleting and rebuilding the
# config. WHY: cloud providers rotate tokens; the user should not need to
# manually delete remotes to recover from expired credentials.
printf '%s\n' "cloud-setup: validating remote credentials with root-only listings..."
_stale_remotes=""
for _remote in $required_remotes; do
  # Suppressed: expected failure when credentials are stale; exit code drives branching.
  if rclone lsd "$_remote:" >/dev/null 2>&1; then
    printf '%s\n' "cloud-setup: ✓ $_remote credentials valid"
  else
    printf '%s\n' "cloud-setup: ✗ $_remote credentials stale or unreachable; will recreate..." >&2
    _stale_remotes="${_stale_remotes:+$_stale_remotes }$_remote"
  fi
done

if [ -n "$_stale_remotes" ]; then
  _rclone_pass_file="$HOME/.config/nucleus/secrets/rclone-config-pass"
  if [ -s "$_rclone_pass_file" ]; then
    RCLONE_CONFIG_PASS="$(cat "$_rclone_pass_file")"
    export RCLONE_CONFIG_PASS
  fi
  for _remote in $_stale_remotes; do
    printf '%s\n' "cloud-setup: deleting and recreating remote '$_remote'..."
    if ! rclone config delete "$_remote"; then
      printf '%s\n' "cloud-setup: warning: could not delete '$_remote' config entry; continuing." >&2
    fi
    _type="$(remote_provider_type "$_remote")"
    _create_args="$(remote_provider_create_args "$_type" "$_remote" "$repo_root")"
    if [ -n "$_create_args" ]; then
      # Word splitting is intentional here: helper output is a whitespace-
      # separated flag list for rclone, not arbitrary user input.
      # shellcheck disable=SC2086
      rclone config create "$_remote" "$_type" $_create_args
    else
      rclone config create "$_remote" "$_type"
    fi
  done

  printf '%s\n' "cloud-setup: re-validating credentials after recreation..."
  _validation_failed=false
  for _remote in $_stale_remotes; do
    # Suppressed: expected failure when recreation did not resolve credentials; exit code drives branching.
    if rclone lsd "$_remote:" >/dev/null 2>&1; then
      printf '%s\n' "cloud-setup: ✓ $_remote credentials valid"
    else
      printf '%s\n' "cloud-setup: ✗ $_remote credentials still invalid after recreation" >&2
      _validation_failed=true
    fi
  done

  if [ "$_validation_failed" = true ]; then
    printf '%s\n' "cloud-setup: credential validation failed after recreation; recheck in 'rclone config'." >&2
    exit 1
  fi
fi

printf '%s\n' "cloud-setup: all credentials valid."

# Sync display names from users.json to rclone config descriptions.
# WHY: rclone description field drives Finder labels and desktop display names.
# When users.json declares a displayName, propagate it to rclone config so
# the mount shows correct labels in Finder and on desktop.
if [ -f "$USERS_JSON" ] && command -v jq >/dev/null 2>&1; then
  printf '%s\n' "cloud-setup: syncing display names from users.json to rclone config..."
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
        | select(.displayName != null and .remoteName != null)
        | [.remoteName, .displayName]
        | @tsv
      ' \
      "$USERS_JSON"
  } 2>/dev/null || true)"

  if [ -n "$_display_names" ]; then
    # shellcheck disable=SC2162  # deliberate tab-split of jq @tsv rows
    while IFS="$(printf '\t')" read remote_name display_name; do
      if [ -z "$remote_name" ] || [ -z "$display_name" ]; then
        continue
      fi

      # Verify remote exists in rclone config before attempting update.
      if ! rclone listremotes | grep -Fxq "${remote_name}:"; then
        continue
      fi

      # Skip no-op updates to avoid unnecessary provider re-auth prompts.
      # WHY: some backends can launch OAuth/device auth flows on config update.
      _current_description="$({
        rclone config dump | jq -r --arg remote "$remote_name" '.[$remote].description // empty'
      } 2>/dev/null || true)"
      if [ "$_current_description" = "$display_name" ]; then
        continue
      fi

      # Update rclone config description field with displayName value.
      # WHY: rclone config update is idempotent and non-destructive; only
      # updates the single 'description' field, leaving all other config intact.
      if rclone config update "$remote_name" description "$display_name"; then
        printf '%s\n' "cloud-setup: updated $remote_name description to '$display_name'"
      else
        printf '%s\n' "cloud-setup: warning: failed to update $remote_name description; continuing with mount restart." >&2
      fi
    done <<EOF
$_display_names
EOF
  fi
fi

if [ -f "$USERS_JSON" ]; then
  restart_cloud_mount_services "$USERS_JSON"
fi

if [ "$skip_apply" = false ]; then
  printf '%s\n' "cloud-setup: running nucleus apply to converge cloud mount services..."
  nix run "$repo_root/src#apply"
fi

printf '%s\n' "cloud-setup: setup complete"
