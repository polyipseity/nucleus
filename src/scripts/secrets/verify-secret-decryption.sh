# Secret decryption health verification (5 checks).
# Consumes __ALL_SOPS_FILES_JSON__, __SSH_PUBKEY_PATH__, __SSH_TO_AGE_BIN__,
# __GNUPG_BIN__, __JQ_BIN__, __GIT_IDENTITY_SECRET_PATH__, __SSH_SECRET_PATH__,
# __SSH_PUBLIC_SECRET_PATH__, __GPG_SECRET_PATH__, __GPG_MANIFEST_PATH__,
# __GNUPG_HOME__ at activation time.
# Expects set -eu and the symlink hardening lib to be sourced before this
# script runs.
set -eu

_vsd_jq_bin='__JQ_BIN__'
_vsd_gnupg_bin='__GNUPG_BIN__'
_vsd_ssh_to_age_bin='__SSH_TO_AGE_BIN__'
_vsd_gpg_home='__GNUPG_HOME__'
_vsd_all_sops_files_json='__ALL_SOPS_FILES_JSON__'

# --- 1. Materialization sanity check ---
for _vsd_path in \
    '__GIT_IDENTITY_SECRET_PATH__' \
    '__SSH_SECRET_PATH__' \
    '__SSH_PUBLIC_SECRET_PATH__' \
    '__GPG_SECRET_PATH__'; do
  if [ ! -s "$_vsd_path" ]; then
    echo "secrets: ERROR — decrypted secret missing or empty at '$_vsd_path'." >&2
    exit 1
  fi
done

# --- 2. GPG key presence in keyring ---
_vsd_gpg_manifest='__GPG_MANIFEST_PATH__'
if [ ! -s "$_vsd_gpg_manifest" ]; then
  echo "secrets: ERROR — managed-gpg-keys manifest missing or empty; gpg-import may have failed." >&2
  exit 1
fi
_vsd_managed_fpr="$(head -n1 "$_vsd_gpg_manifest")"
# Dump all secret-key fingerprints once and cache the colon-format output;
# reused by check 3 to avoid repeated invocations.  --with-colons forces
# machine-readable non-interactive output; --no-autostart prevents GPG from
# launching a new agent daemon (which deadlocks on macOS when the agent
# socket directory is not yet ready during non-interactive activation).
# undoc-supp: GnuPG may fail if GNUPGHOME doesn't exist yet on first activation; the subsequent grep check handles empty output.
_vsd_gpg_all_secret_fprs="$(GNUPGHOME="$_vsd_gpg_home" \
  "$_vsd_gnupg_bin" --with-colons --no-autostart --list-secret-keys)" || true  # undoc-supp: GnuPG may fail on first activation
if ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_managed_fpr"; then
  echo "secrets: ERROR — managed GPG key $_vsd_managed_fpr not in keyring after gpg-import." >&2
  exit 1
fi

# --- 3. GPG SOPS recipient check for all SOPS files ---
# Rather than live-decrypting with GPG (which requires the private key
# passphrase and fails non-interactively), extract the fp: value from each
# SOPS file's plaintext sops.pgp[].fp metadata (always unencrypted) and
# verify that fingerprint is present in our secret keyring.  SOPS records
# the encryption SUBKEY fingerprint in the fp: field, not the primary key
# fingerprint, so comparing the primary fingerprint directly produces false
# failures when SOPS chose a subkey (e.g., a Kyber encryption subkey).
# Combined with check 2 (primary key in keyring), this confirms we have the
# private key material to decrypt once the passphrase is provided.
# YAML SOPS files store fp as "    fp: HEX" (unquoted); binary SOPS files
# (e.g. wallpaper blobs) use JSON format with "\"fp\": \"HEX\"".  The
# extraction below handles both formats.
_vsd_gpg_failures=""
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.path')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.displayName')"
  # Binary SOPS files use JSON format ("fp": "HEX") while YAML SOPS files
  # use "    fp: HEX".  The combined -E pattern matches both; the second
  # grep -oE extracts the hex fingerprint directly, avoiding the need for
  # undoc-supp: grep may find no match; soft-fail prevents silent set -e exit, allowing [ -z ] below to report cleanly.
  _vsd_sops_gpg_fp="$(/usr/bin/grep -m1 -E '[[:space:]]fp: |"fp": ' "$_vsd_path" | /usr/bin/grep -oE '[0-9A-Fa-f]{40,}')" || true
  if [ -z "$_vsd_sops_gpg_fp" ] || \
      ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_sops_gpg_fp"; then
    _vsd_gpg_failures="$_vsd_gpg_failures ${_vsd_display_name}"
  fi
done < <(printf '%s\n' "$_vsd_all_sops_files_json" | "$_vsd_jq_bin" -r -c '.[]')
if [ -n "$_vsd_gpg_failures" ]; then
  echo "secrets: ERROR — GPG SOPS decryption check failed for:$_vsd_gpg_failures; managed GPG key may not be registered in .sops.yaml." >&2
  exit 1
fi

# --- 4. Personal SSH age recipient check for all SOPS files ---
# Rather than live-decrypting with the SSH private key (which requires the
# key passphrase and fails non-interactively), derive the age public key
# from the managed personal SSH public key via ssh-to-age -i (passphrase-
# free public-key conversion) and verify it appears in each SOPS file's
# plaintext sops.age[] metadata.  YAML SOPS files store the key as
# "recipient: age1..." (unquoted); binary SOPS files (e.g. wallpaper blobs)
# use JSON format "\"recipient\": \"age1...\"" (quoted key and value).
# Searching for the bare age key value with grep -qF handles both formats.
# No private key material is accessed.
_vsd_ssh_age_pub=""
_vsd_ssh_failures=""
# undoc-supp: ssh-to-age may fail if the SSH public key hasn't been materialized yet (first bootstrap); empty result is handled below.
_vsd_ssh_age_pub="$("$_vsd_ssh_to_age_bin" -i '__SSH_PUBKEY_PATH__')" || true
if [ -z "$_vsd_ssh_age_pub" ]; then
  echo "secrets: ERROR — personal SSH key age-backend SOPS decryption check failed for: <ssh-to-age pubkey derivation failed>; ensure __SSH_PUBKEY_PATH__ is a valid Ed25519 public key." >&2
  exit 1
fi
while IFS= read -r _vsd_entry; do
  [ -z "$_vsd_entry" ] && continue
  _vsd_path="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.path')"
  _vsd_display_name="$(printf '%s\n' "$_vsd_entry" | "$_vsd_jq_bin" -r '.displayName')"
  # Search for the bare age key value rather than the full "recipient: KEY"
  # string: YAML SOPS stores "recipient: KEY" (unquoted) while binary SOPS
  # uses JSON "\"recipient\": \"KEY\"" (quoted key and value).  The age key
  # is a unique 59+ character bech32 string that identifies the recipient
  # unambiguously without the surrounding field label.
  if ! /usr/bin/grep -qF "$_vsd_ssh_age_pub" "$_vsd_path"; then
    _vsd_ssh_failures="$_vsd_ssh_failures ${_vsd_display_name}"
  fi
done < <(printf '%s\n' "$_vsd_all_sops_files_json" | "$_vsd_jq_bin" -r -c '.[]')
if [ -n "$_vsd_ssh_failures" ]; then
  echo "secrets: ERROR — personal SSH key age-backend SOPS decryption check failed for:$_vsd_ssh_failures; SSH key may not be registered in .sops.yaml as an age recipient." >&2
  exit 1
fi

# --- 5. Machine age key existence check (warning-only) ---
# Warning-only: on first bootstrap the host SSH key may not yet be registered
# in .sops.yaml as a device age recipient, so the derived key file may be
# absent.  Once deriveHostAgeKey (posix-sops.nix) has run and the machine
# age recipient is in .sops.yaml, this check will pass silently on every
# subsequent apply.
if [ ! -f "/etc/sops/age/machine.txt" ]; then
  echo "secrets: warning — /etc/sops/age/machine.txt missing; this machine cannot be a SOPS age device recipient until the host key is registered in .sops.yaml and deriveHostAgeKey has run successfully." >&2
fi
