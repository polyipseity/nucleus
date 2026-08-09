#!/usr/bin/env bash
# Decrypts src/secrets/users/<username>.yml and materializes GPG, SSH, Git, and
# rclone payloads for the current Home Manager user.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

_mus_repo_root="$1"
_mus_username="$2"
_mus_gpg_bin="$3"
_mus_git_bin="$4"
_mus_ssh_keygen_bin="$5"
_mus_ssh_add_bin="$6"
_mus_sops_bin="$7"
_mus_host_key_path="$8"
_mus_machine_age_key_path="$9"

_mus_user_secret_file="$_mus_repo_root/src/secrets/users/${_mus_username}.yml"
if [ ! -f "$_mus_user_secret_file" ]; then
  exit 0
fi

_mus_jq_bin="$(command -v jq)" || {
  echo "materialize-user-secrets: jq is required but not found in PATH." >&2
  exit 1
}

_mus_decrypt_json="$(
  "$SCRIPT_DIR/decrypt-sops.sh" \
    --repo-root "$_mus_repo_root" \
    --sops-file "$_mus_user_secret_file" \
    --sops-bin "$_mus_sops_bin" \
    --gpg-bin "$_mus_gpg_bin" \
    --host-key-path "$_mus_host_key_path" \
    --machine-age-key-path "$_mus_machine_age_key_path" \
    --gnupg-home "${GNUPGHOME:-$HOME/.gnupg}"
)"

_mus_should_skip_key() {
  case "$1" in
  sops | jellyfin_* | vm_guest_*)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

_mus_ssh_dir="$HOME/.ssh"
_mus_nucleus_config_dir="$HOME/.config/nucleus"
_mus_nucleus_secrets_dir="$_mus_nucleus_config_dir/secrets"
_mus_managed_ssh_key_paths="$_mus_nucleus_config_dir/managed-ssh-key-paths"
_mus_primary_ssh_pub="$_mus_ssh_dir/ssh_personal_${_mus_username}.pub"

mkdir -p "$_mus_ssh_dir" "$_mus_nucleus_secrets_dir"
chmod 700 "$_mus_ssh_dir" "$_mus_nucleus_config_dir" "$_mus_nucleus_secrets_dir"

_mus_gpg_temp_files=()
_mus_cleanup() {
  local gpg_temp_file
  for gpg_temp_file in "${_mus_gpg_temp_files[@]}"; do
    rm -f "$gpg_temp_file"
  done
}
trap _mus_cleanup EXIT

_mus_git_identity_temp=""
_mus_private_ssh_paths=()

while IFS= read -r _mus_key; do
  [ -n "$_mus_key" ] || continue
  if _mus_should_skip_key "$_mus_key"; then
    continue
  fi

  # shellcheck disable=SC2016 # reason: $key is jq --arg variable, not shell expansion
  _mus_value="$(printf '%s\n' "$_mus_decrypt_json" | "$_mus_jq_bin" -r --arg key "$_mus_key" '.[ $key ]')"

  case "$_mus_key" in
  gpg_*)
    _mus_gpg_temp="$(mktemp)"
    printf '%s' "$_mus_value" >"$_mus_gpg_temp"
    _mus_gpg_temp_files+=("$_mus_gpg_temp")
    ;;
  ssh_*)
    _mus_relative_path="${_mus_key#ssh_}"
    _mus_ssh_target="$_mus_ssh_dir/$_mus_relative_path"
    _mus_ssh_target_dir="$(dirname -- "$_mus_ssh_target")"
    mkdir -p "$_mus_ssh_target_dir"
    # Replace stale sops-nix symlinks from older generations before writing.
    rm -f "$_mus_ssh_target"
    printf '%s' "$_mus_value" >"$_mus_ssh_target"
    case "$_mus_relative_path" in
    *.pub)
      chmod 0644 "$_mus_ssh_target"
      ;;
    *)
      chmod 0600 "$_mus_ssh_target"
      _mus_private_ssh_paths+=("$_mus_ssh_target")
      ;;
    esac
    ;;
  git_identity)
    _mus_git_identity_temp="$(mktemp)"
    printf '%s' "$_mus_value" >"$_mus_git_identity_temp"
    ;;
  rclone_config_pass)
    _mus_rclone_pass_path="$_mus_nucleus_secrets_dir/rclone-config-pass"
    printf '%s' "$_mus_value" >"$_mus_rclone_pass_path"
    chmod 0400 "$_mus_rclone_pass_path"
    ;;
  *)
    ;;
  esac
done < <(printf '%s\n' "$_mus_decrypt_json" | "$_mus_jq_bin" -r 'keys[]')

if [ "${#_mus_gpg_temp_files[@]}" -gt 0 ]; then
  "$SCRIPT_DIR/import-gpg-key.sh" \
    "${GNUPGHOME:-$HOME/.gnupg}" \
    "$_mus_gpg_bin" \
    "${_mus_gpg_temp_files[@]}"
fi

if [ -n "$_mus_git_identity_temp" ]; then
  "$SCRIPT_DIR/configure-git-identity.sh" "$_mus_git_identity_temp" "$_mus_git_bin"
  rm -f "$_mus_git_identity_temp"
  _mus_git_identity_temp=""
fi

{
  for _mus_private_path in "${_mus_private_ssh_paths[@]}"; do
    printf '%s\n' "$_mus_private_path"
  done
} >"$_mus_managed_ssh_key_paths"
chmod 600 "$_mus_managed_ssh_key_paths"

if [ -f "$_mus_primary_ssh_pub" ]; then
  "$SCRIPT_DIR/adopt-ssh-key.sh" \
    "$_mus_primary_ssh_pub" \
    "$_mus_ssh_keygen_bin" \
    "$_mus_ssh_add_bin"
fi
