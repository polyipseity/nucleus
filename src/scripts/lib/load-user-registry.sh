#!/usr/bin/env bash
# src/scripts/lib/load-user-registry.sh — Assemble the user registry from
# src/users/<username>/ domain JSON files with src/users/default/ fallback.
#
# Outputs the assembled registry as JSON on stdout (username-keyed object).
#
# Usage:
#   load-user-registry.sh [--host MacBook|NixOS|Windows] [--repo-root PATH]
#
# Environment:
#   NUCLEUS_REPO_ROOT  Repository root when --repo-root is omitted.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

_hostName="MacBook"
_repo_root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      _hostName="${2:?--host requires a value}"
      shift 2
      ;;
    --repo-root)
      _repo_root="${2:?--repo-root requires a value}"
      shift 2
      ;;
    -h | --help)
      usage_std "load-user-registry.sh" "[--host MacBook|NixOS|Windows] [--repo-root PATH]" \
        "Assemble user registry JSON from src/users/ domain files."
      exit 0
      ;;
    *)
      error "unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ -z "$_repo_root" ]; then
  _repo_root="$(derive_repo_root)"
fi

_users_root="$_repo_root/src/users"
_default_root="$_users_root/default"

if [ ! -d "$_users_root" ]; then
  error "users root not found: $_users_root"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq is required to assemble the user registry"
  exit 1
fi

_lur_merge_json() {
  _lm_default_file="$1"
  _lm_user_file="$2"
  if [ -f "$_lm_default_file" ] && [ -f "$_lm_user_file" ]; then
    jq -s 'add' "$_lm_default_file" "$_lm_user_file"
  elif [ -f "$_lm_user_file" ]; then
    jq '.' "$_lm_user_file"
  elif [ -f "$_lm_default_file" ]; then
    jq '.' "$_lm_default_file"
  else
    echo '{}'
  fi
}

_lur_strip_schema() {
  jq 'del(."$schema")'
}

_lur_resolve_cloud_drives() {
  jq --arg host "$_hostName" '
    def resolve_scalar($h):
      if type == "object" and (keys | all(. == "MacBook" or . == "NixOS" or . == "Windows")) then
        .[$h]
      else
        .
      end;
    def resolve_item($h):
      . as $item
      | ($item | if has("localPath") then .localPath = (.localPath | resolve_scalar($h)) else . end)
      | (if has("enable") then .enable = (.enable | resolve_scalar($h)) else . end)
      | (if has("readWrite") then .readWrite = (.readWrite | resolve_scalar($h)) else . end)
      | (if has("fallbackTimer") and (.fallbackTimer | type) == "object" and (.fallbackTimer | has("enable")) then
          .fallbackTimer.enable = (.fallbackTimer.enable | resolve_scalar($h))
        else
          .
        end);
    {
      mounts: ((.mounts // []) | map(resolve_item($host))),
      replicas: ((.replicas // []) | map(resolve_item($host))),
      replicaGc: (.replicaGc // {})
    }
  '
}

_lur_resolve_dev_repos() {
  jq --arg host "$_hostName" '
    def resolve_scalar($h):
      if type == "object" and (keys | all(. == "MacBook" or . == "NixOS" or . == "Windows")) then
        .[$h]
      else
        .
      end;
    .repositories = ((.repositories // []) | map(if has("target") then .target = (.target | resolve_scalar($host)) else . end))
  '
}

_lur_resolve_profile() {
  jq --arg host "$_hostName" '
    if has("homeDirectory") and ((.homeDirectory | type) == "object") then
      .homeDirectory = .homeDirectory[$host]
    else
      .
    end
  '
}

_lur_assemble_user() {
  _au_username="$1"
  _au_user_dir="$_users_root/$_au_username"

  _profile="$(_lur_merge_json "$_default_root/profile.json" "$_au_user_dir/profile.json" | _lur_strip_schema | _lur_resolve_profile)"
  _cloud_drives="$(_lur_merge_json "$_default_root/cloud-drives.json" "$_au_user_dir/cloud-drives.json" | _lur_strip_schema | _lur_resolve_cloud_drives)"
  _custom_symlinks="$(_lur_merge_json "$_default_root/custom-provision-symlinks.json" "$_au_user_dir/custom-provision-symlinks.json" | _lur_strip_schema | jq '.customProvisionSymlinks // []')"
  _dev_repos="$(_lur_merge_json "$_default_root/dev-repos.json" "$_au_user_dir/dev-repos.json" | _lur_strip_schema | _lur_resolve_dev_repos)"
  _env_vars="$(_lur_merge_json "$_default_root/env-vars.json" "$_au_user_dir/env-vars.json" | _lur_strip_schema)"
  _icloud="$(_lur_merge_json "$_default_root/icloud-exclusions.json" "$_au_user_dir/icloud-exclusions.json" | _lur_strip_schema)"
  _jellyfin="$(_lur_merge_json "$_default_root/jellyfin.json" "$_au_user_dir/jellyfin.json" | _lur_strip_schema)"
  _password_store="$(_lur_merge_json "$_default_root/password-store.json" "$_au_user_dir/password-store.json" | _lur_strip_schema)"
  _services="$(_lur_merge_json "$_default_root/services.json" "$_au_user_dir/services.json" | _lur_strip_schema)"
  _vm_guest="$(_lur_merge_json "$_default_root/vm-guest.json" "$_au_user_dir/vm-guest.json" | _lur_strip_schema)"
  _windows="$(_lur_merge_json "$_default_root/windows.json" "$_au_user_dir/windows.json" | _lur_strip_schema)"

  jq -n \
    --argjson profile "$_profile" \
    --argjson cloudDrives "$_cloud_drives" \
    --argjson customProvisionSymlinks "$_custom_symlinks" \
    --argjson devRepos "$_dev_repos" \
    --argjson envVars "$_env_vars" \
    --argjson iCloudExclusions "$_icloud" \
    --argjson jellyfin "$_jellyfin" \
    --argjson passwordStore "$_password_store" \
    --argjson services "$_services" \
    --argjson vmGuest "$_vm_guest" \
    --argjson windows "$_windows" \
    '{
      isPrimary: ($profile.isPrimary // false),
      homeDirectory: ($profile.homeDirectory // null),
      cloudDrives: $cloudDrives,
      customProvisionSymlinks: $customProvisionSymlinks,
      devRepos: $devRepos,
      envVars: $envVars,
      iCloudExclusions: $iCloudExclusions,
      jellyfin: $jellyfin,
      passwordStore: $passwordStore,
      services: $services,
      vmGuest: $vmGuest,
      dscConfigFiles: ($windows.dscConfigFiles // []),
      description: ($windows.description // "")
    }'
}

_result='{}'
for _username in "$_users_root"/*; do
  [ -d "$_username" ] || continue
  _name="$(basename "$_username")"
  case "$_name" in
    default) continue ;;
  esac
  _user_json="$(_lur_assemble_user "$_name")"
  _result="$(echo "$_result" | jq --arg name "$_name" --argjson user "$_user_json" '. + {($name): $user}')"
done

echo "$_result"
