#!/usr/bin/env bash
# Secret decryption health verification: materialization, GPG presence, GPG and SSH age
# recipients, machine age key. Takes the SOPS manifest, materialized paths, and tool paths.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_vsd_jq_bin="$1"
_vsd_gnupg_bin="$2"
_vsd_ssh_to_age_bin="$3"
_vsd_ssh_keygen_bin="$4"
_vsd_gpg_home="$5"
_vsd_all_sops_files_json="$6"
_vsd_git_identity_path="$7"
_vsd_ssh_private_key_path="$8"
_vsd_ssh_public_key_path="$9"
shift 9
_vsd_gpg_manifest_path="$1"
_vsd_ssh_key_paths_manifest="$2"
_vsd_ssh_adopt_manifest="$3"

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
  # A file that exists is not a key that works: an unparsable private key makes ssh report
  # "invalid format" and fall back to no authentication, and a running agent hides that by
  # answering first. Prove OpenSSH can read it.
  #
  # Two parts, because neither alone is enough. The header check rejects a bare .pub file,
  # which ssh-keygen -l happily fingerprints. The -l check then proves the container parses;
  # it reads the cleartext public-key blob out of the openssh-key-v1 format, so it works on
  # a protected key without the passphrase and never prompts. Deriving with -y -P '' would
  # be wrong: the empty passphrase is simply incorrect for a protected key.
  #
  # WHY: the probe runs through a symlink in a private temp dir. Given the managed key path
  # directly, ssh-keygen -l prefers the sibling <key>.pub and reports that key's fingerprint,
  # never reading the private key. Every managed key has its .pub beside it, so probing in
  # place would pass a corrupt private key. A symlink has no sibling to pick up, and unlike a
  # copy it never puts key material in a second place.
  _vsd_probe_dir="$(/usr/bin/mktemp -d)"
  trap '/bin/rm -rf "$_vsd_probe_dir"' EXIT
  /bin/ln -s "$_vsd_private_key_path" "$_vsd_probe_dir/key"

  if ! /usr/bin/grep -qE '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----$' "$_vsd_private_key_path"; then
    die -l secrets "managed SSH private key at '$_vsd_private_key_path' is not a valid OpenSSH private key (no private-key PEM header); fix the SOPS value or re-run materialize-user-secrets."
  fi
  # check-suppress:suppression_doc: ssh-keygen -l exits non-zero for a malformed or truncated key; the empty output is reported below with the file name.
  _vsd_key_fingerprint="$("$_vsd_ssh_keygen_bin" -l -f "$_vsd_probe_dir/key" </dev/null)" || true
  if [ -z "$_vsd_key_fingerprint" ]; then
    die -l secrets "managed SSH private key at '$_vsd_private_key_path' is not a valid OpenSSH private key (ssh-keygen -l could not read it); fix the SOPS value or re-run materialize-user-secrets."
  fi
  /bin/rm -rf "$_vsd_probe_dir"
  trap - EXIT
done <"$_vsd_ssh_key_paths_manifest"

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

_vsd_machine_age_key="$(nucleus_machine_age_key_path)"
if [ ! -f "$_vsd_machine_age_key" ]; then
  warn -l secrets "$_vsd_machine_age_key missing; this machine cannot be a SOPS age device recipient until the host key is registered in .sops.yaml and derive-host-age-key.sh has run successfully."
fi
