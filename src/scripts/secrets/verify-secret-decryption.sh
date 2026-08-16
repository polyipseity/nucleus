#!/usr/bin/env bash
# Secret decryption health verification (5 checks).
# Consumes SOPS file manifest, materialized artefact paths, and tool paths at activation time.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_vsd_jq_bin="$1"
_vsd_gnupg_bin="$2"
_vsd_ssh_to_age_bin="$3"
_vsd_gpg_home="$4"
_vsd_all_sops_files_json="$5"
_vsd_git_identity_path="$6"
_vsd_ssh_private_key_path="$7"
_vsd_ssh_public_key_path="$8"
shift 8
_vsd_gpg_manifest_path="$1"
_vsd_ssh_key_paths_manifest="$2"
_vsd_ssh_adopt_manifest="$3"

# --- 1. Materialization sanity check ---
for _vsd_path in \
  "$_vsd_git_identity_path" \
  "$_vsd_ssh_private_key_path" \
  "$_vsd_ssh_public_key_path" \
  "$_vsd_gpg_manifest_path" \
  "$_vsd_ssh_key_paths_manifest" \
  "$_vsd_ssh_adopt_manifest"; do
  if [ ! -s "$_vsd_path" ]; then
    die -l secrets "managed secret artefact missing or empty at '$_vsd_path'."
  fi
done

while IFS= read -r _vsd_private_key_path; do
  [ -n "$_vsd_private_key_path" ] || continue
  if [ ! -s "$_vsd_private_key_path" ]; then
    die -l secrets "managed SSH private key missing or empty at '$_vsd_private_key_path'."
  fi
done <"$_vsd_ssh_key_paths_manifest"

# --- 2. GPG key presence in keyring ---
_vsd_gpg_manifest="$_vsd_gpg_manifest_path"
# check-suppress:suppression_doc: GnuPG may fail if GNUPGHOME doesn't exist yet on first activation; the subsequent grep check handles empty output.
_vsd_gpg_all_secret_fprs="$(GNUPGHOME="$_vsd_gpg_home" \
  "$_vsd_gnupg_bin" --with-colons --no-autostart --list-secret-keys)" || true # check-suppress:suppression_doc: GnuPG may fail on first activation
while IFS= read -r _vsd_managed_fpr; do
  [ -n "$_vsd_managed_fpr" ] || continue
  if ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_managed_fpr"; then
    die -l secrets "managed GPG key $_vsd_managed_fpr not in keyring after materialize-user-secrets."
  fi
done <"$_vsd_gpg_manifest"

# --- 3. GPG SOPS recipient check for all SOPS files ---
_vsd_gpg_failures=""
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.path')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.displayName')"
  # check-suppress:suppression_doc: grep may find no match; soft-fail prevents silent set -e exit, allowing [ -z ] below to report cleanly.
  _vsd_sops_gpg_fp="$(/usr/bin/grep -m1 -E '[[:space:]]fp: |"fp": ' "$_vsd_path" | /usr/bin/grep -oE '[0-9A-Fa-f]{40,}')" || true
  if [ -z "$_vsd_sops_gpg_fp" ] ||
    ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_sops_gpg_fp"; then
    _vsd_gpg_failures="$_vsd_gpg_failures ${_vsd_display_name}"
  fi
done < <(printf '%s\n' "$_vsd_all_sops_files_json" | "$_vsd_jq_bin" -r -c '.[]')
if [ -n "$_vsd_gpg_failures" ]; then
  die -l secrets "GPG SOPS decryption check failed for:$_vsd_gpg_failures; managed GPG key may not be registered in .sops.yaml."
fi

# --- 4. Personal SSH age recipient check for all SOPS files ---
_vsd_ssh_age_pub=""
_vsd_ssh_failures=""
# check-suppress:suppression_doc: ssh-to-age may fail if the SSH public key hasn't been materialized yet (first bootstrap); empty result is handled below.
_vsd_ssh_age_pub="$("$_vsd_ssh_to_age_bin" -i "$_vsd_ssh_public_key_path")" || true
if [ -z "$_vsd_ssh_age_pub" ]; then
  die -l secrets "personal SSH key age-backend SOPS decryption check failed for: <ssh-to-age pubkey derivation failed>; ensure $_vsd_ssh_public_key_path is a valid Ed25519 public key."
fi
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.path')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.displayName')"
  if ! /usr/bin/grep -qF "$_vsd_ssh_age_pub" "$_vsd_path"; then
    _vsd_ssh_failures="$_vsd_ssh_failures ${_vsd_display_name}"
  fi
done < <(printf '%s\n' "$_vsd_all_sops_files_json" | "$_vsd_jq_bin" -r -c '.[]')
if [ -n "$_vsd_ssh_failures" ]; then
  die -l secrets "personal SSH key age-backend SOPS decryption check failed for:$_vsd_ssh_failures; SSH key may not be registered in .sops.yaml as an age recipient."
fi

# --- 5. Machine age key existence check (warning-only) ---
if [ ! -f "/etc/sops/age/machine.txt" ]; then
  warn -l secrets "/etc/sops/age/machine.txt missing; this machine cannot be a SOPS age device recipient until the host key is registered in .sops.yaml and deriveHostAgeKey has run successfully."
fi
