#!/usr/bin/env bash
# Decrypts a SOPS file using machine key, then all users' SSH age keys, then GPG.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck source=../lib/resolve-user-homedir.sh
. "$SCRIPT_DIR/../lib/resolve-user-homedir.sh"

_ds_repo_root=""
_ds_sops_file=""
_ds_sops_bin="sops"
_ds_gpg_bin="gpg"
_ds_host_key_path="/etc/ssh/ssh_host_ed25519_key"
_ds_machine_age_key_path="/etc/sops/age/machine.txt"
_ds_gnupg_home="${GNUPGHOME:-$HOME/.gnupg}"

usage() {
  cat <<'EOF' >&2
Usage: decrypt-sops.sh --repo-root <path> --sops-file <path> [options]

Options:
  --repo-root <path>           Repository root
  --sops-file <path>           SOPS-encrypted file to decrypt
  --sops-bin <path>            sops executable (default: sops)
  --gpg-bin <path>             gpg executable (default: gpg)
  --host-key-path <path>       Machine SSH host private key
  --machine-age-key-path <path> Derived machine age key file
  --gnupg-home <path>          GnuPG homedir for GPG fallback
  --output-type <fmt>          sops output type (default: json)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      _ds_repo_root="$2"
      shift 2
      ;;
    --sops-file)
      _ds_sops_file="$2"
      shift 2
      ;;
    --sops-bin)
      _ds_sops_bin="$2"
      shift 2
      ;;
    --gpg-bin)
      _ds_gpg_bin="$2"
      shift 2
      ;;
    --host-key-path)
      _ds_host_key_path="$2"
      shift 2
      ;;
    --machine-age-key-path)
      _ds_machine_age_key_path="$2"
      shift 2
      ;;
    --gnupg-home)
      _ds_gnupg_home="$2"
      shift 2
      ;;
    --output-type)
      _ds_output_format="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "decrypt-sops: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

_ds_output_format="${_ds_output_format:-json}"

if [ -z "$_ds_repo_root" ] || [ -z "$_ds_sops_file" ]; then
  usage
  exit 2
fi

if [ ! -f "$_ds_sops_file" ]; then
  echo "decrypt-sops: file not found: $_ds_sops_file" >&2
  exit 1
fi

_ds_decrypt_with_env() {
  "$_ds_sops_bin" --decrypt --output-type "$_ds_output_format" "$_ds_sops_file"
}

_ds_clear_age_env() {
  unset SOPS_AGE_SSH_PRIVATE_KEY_FILE
  unset SOPS_AGE_KEY_FILE
}

# Step 1: machine SSH host key (only when readable), then derived machine age key.
if [ -r "$_ds_host_key_path" ]; then
  SOPS_AGE_SSH_PRIVATE_KEY_FILE="$_ds_host_key_path"
  export SOPS_AGE_SSH_PRIVATE_KEY_FILE
  if _ds_decrypt_with_env; then
    _ds_clear_age_env
    exit 0
  fi
  _ds_clear_age_env
fi

if [ -f "$_ds_machine_age_key_path" ]; then
  SOPS_AGE_KEY_FILE="$_ds_machine_age_key_path"
  export SOPS_AGE_KEY_FILE
  if _ds_decrypt_with_env; then
    _ds_clear_age_env
    exit 0
  fi
  _ds_clear_age_env
fi

# Step 2: all users' materialized SSH private keys (alphabetical).
while IFS= read -r _ds_username; do
  [ -n "$_ds_username" ] || continue
  _ds_user_home=""
  if ! _ds_user_home="$(resolve_user_homedir "$_ds_username")"; then
    continue
  fi

  _ds_manifest="$_ds_user_home/.config/nucleus/managed-ssh-key-paths"
  if [ ! -f "$_ds_manifest" ]; then
    continue
  fi

  while IFS= read -r _ds_private_key_path; do
    [ -n "$_ds_private_key_path" ] || continue
    if [ ! -f "$_ds_private_key_path" ]; then
      continue
    fi
    SOPS_AGE_SSH_PRIVATE_KEY_FILE="$_ds_private_key_path"
    export SOPS_AGE_SSH_PRIVATE_KEY_FILE
    if _ds_decrypt_with_env; then
      _ds_clear_age_env
      exit 0
    fi
    _ds_clear_age_env
  done < "$_ds_manifest"
done < <(list_secret_users "$_ds_repo_root")

# Step 3: GPG keyring.
if GNUPGHOME="$_ds_gnupg_home" "$_ds_gpg_bin" --with-colons --no-autostart --list-secret-keys 2>/dev/null | /usr/bin/grep -qE '^(sec|ssb):'; then
  _ds_clear_age_env
  if GNUPGHOME="$_ds_gnupg_home" _ds_decrypt_with_env; then
    exit 0
  fi
fi

_ds_clear_age_env
echo "decrypt-sops: unable to decrypt '$_ds_sops_file' with machine key, user SSH keys, or GPG keyring" >&2
exit 1
