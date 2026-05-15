#!/usr/bin/env sh
# Guides one-time cloud remote setup and converges cloud mount automation.
#
# Operations:
#   1. verify required rclone remotes exist (GoogleDrive, iCloud, OneDrive)
#   2. if any are missing, create each with the correct provider type and
#      repo-configured backend defaults, then prompt for authentication
#      (no manual menu navigation required)
#   3. run nucleus apply so cloud mount services/units converge immediately
#
# Arguments:
#   --skip-apply  validate/setup remotes only; do not run apply
#
# Exit conditions:
#   0 on success; non-zero when required remotes are still missing after setup.

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

skip_apply=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-apply)
      skip_apply=true
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
# The iCloud backend has required fields like `apple_id` with no safe default,
# so `--all` is required there to force the interactive question flow. The
# iCloud service choice is passed as an explicit option so rclone skips the
# drive-vs-photos question and jumps straight to Apple ID/password/2FA.
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

required_remotes="GoogleDrive iCloud OneDrive"
missing_remotes="$(collect_missing_remotes "$required_remotes")" || {
  printf '%s\n' "cloud-setup: failed to read rclone remotes. Run 'rclone config' manually and retry." >&2
  exit 1
}

if [ -n "$missing_remotes" ]; then
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

if [ "$skip_apply" = false ]; then
  printf '%s\n' "cloud-setup: running nucleus apply to converge cloud mount services..."
  nix run "$repo_root/src#apply"
fi

printf '%s\n' "cloud-setup: setup complete"
