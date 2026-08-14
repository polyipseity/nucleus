#!/usr/bin/env bash
# Imports managed GPG private key material from one or more secret blobs into
# the keyring and enforces ultimate ownertrust on each managed primary fingerprint.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_gnupghome="$1"
_gpg_bin="$2"
shift 2
_gpg_secret_paths=("$@")

if [ "${#_gpg_secret_paths[@]}" -eq 0 ]; then
  die -l gpg-import "no GPG secret paths provided; nothing to import."
fi

mkdir -p "$_gnupghome"
chmod 700 "$_gnupghome"

nucleus_config_dir="$HOME/.config/nucleus"
managed_keys_manifest="$nucleus_config_dir/managed-gpg-keys"

_gpg_fingerprint_from_secret() {
  local secret_path="$1"
  # check-suppress:suppression_doc: GPG may emit non-zero exit for malformed/dry-run key material during import-options dry-run; the [ -z ] guard below catches and reports an empty result explicitly.
  "$_gpg_bin" --batch --import-options show-only --dry-run --with-colons --import "$secret_path" | /usr/bin/awk -F: '$1 == "fpr" { print $10; exit }' || true
}

current_fingerprints=()
for _gpg_secret_path in "${_gpg_secret_paths[@]}"; do
  if [ ! -f "$_gpg_secret_path" ]; then
    die -l gpg-import "missing decrypted GPG secret at '$_gpg_secret_path'; cannot import key material."
  fi

  first_key_fingerprint="$(_gpg_fingerprint_from_secret "$_gpg_secret_path")"
  if [ -z "$first_key_fingerprint" ]; then
    die -l secrets "could not determine managed primary fingerprint for '$_gpg_secret_path' before import."
  fi

  current_fingerprints+=("$first_key_fingerprint")
done

# Remove stale managed keys recorded in the manifest but absent from the
# current secret set.  Guard on a non-empty current fingerprint set so a dry-run
# parse failure never triggers deletion.
if [ "${#current_fingerprints[@]}" -gt 0 ] && [ -f "$managed_keys_manifest" ]; then
  while IFS= read -r stale_fpr; do
    [ -z "$stale_fpr" ] && continue
    stale_is_current=0
    for current_fpr in "${current_fingerprints[@]}"; do
      if [ "$stale_fpr" = "$current_fpr" ]; then
        stale_is_current=1
        break
      fi
    done
    if [ "$stale_is_current" -eq 0 ]; then
      if "$_gpg_bin" --batch --list-secret-keys "$stale_fpr" >/dev/null 2>&1; then
        if ! "$_gpg_bin" --batch --yes --delete-secret-and-public-key "$stale_fpr"; then
          warn -l gpg-import "warning — failed to delete stale managed GPG key $stale_fpr from keyring."
        else
          say -l gpg-import "deleted stale managed GPG key $stale_fpr."
        fi
      fi
    fi
  done <"$managed_keys_manifest"
fi

for _gpg_secret_path in "${_gpg_secret_paths[@]}"; do
  if ! "$_gpg_bin" --import "$_gpg_secret_path"; then
    die -l secrets "gpg import failed for GPG secret '$_gpg_secret_path'."
  fi
done

mkdir -p "$nucleus_config_dir"
{
  for current_fpr in "${current_fingerprints[@]}"; do
    printf '%s\n' "$current_fpr"
  done
} >"$managed_keys_manifest"
chmod 600 "$managed_keys_manifest"

for current_fpr in "${current_fingerprints[@]}"; do
  if ! printf '%s:6:\n' "$current_fpr" | "$_gpg_bin" --import-ownertrust; then
    warn -l secrets "warning — failed to enforce ultimate ownertrust for managed primary fingerprint $current_fpr; key is imported and tracked but trust state may require manual repair."
  fi
done
