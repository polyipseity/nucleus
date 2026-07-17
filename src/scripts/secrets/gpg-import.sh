# Imports the managed GPG private key from SOPS into the keyring and
# enforces ultimate ownertrust on the managed primary fingerprint.
# Requires: GNUPGHOME, GPG_BIN, GPG_SECRET_PATH env vars.

mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

if [ ! -f "$GPG_SECRET_PATH" ]; then
  echo "gpg-import: missing decrypted GPG secret at $GPG_SECRET_PATH; cannot import key material." >&2
  exit 1
fi

# Extract the primary fingerprint from the managed secret without importing.
# The `exit` in awk stops at the first fpr record, giving the primary key
# fingerprint rather than a subkey fingerprint.
# undoc-supp: GPG may emit non-zero exit for malformed/dry-run key material during
# import-options dry-run; the [ -z ] guard below catches and reports
# an empty result explicitly.
first_key_fingerprint="$("$GPG_BIN" --batch --import-options show-only --dry-run --with-colons --import "$GPG_SECRET_PATH" | /usr/bin/awk -F: '$1 == "fpr" { print $10; exit }')" || true  # undoc-supp: GPG may exit non-zero on dry-run parse issues; [ -z ] guard below catches empty result explicitly.

# Remove stale managed keys: those we imported previously (per manifest)
# that are no longer the current managed key.  Guard on a non-empty
# first_key_fingerprint so a dry-run parse failure never triggers deletion.
nucleus_config_dir="$HOME/.config/nucleus"
managed_keys_manifest="$nucleus_config_dir/managed-gpg-keys"
if [ -n "$first_key_fingerprint" ] && [ -f "$managed_keys_manifest" ]; then
  while IFS= read -r stale_fpr; do
    [ -z "$stale_fpr" ] && continue
    if [ "$stale_fpr" != "$first_key_fingerprint" ]; then
      # Only delete if the key is actually present in the keyring.
      if "$GPG_BIN" --batch --list-secret-keys "$stale_fpr" >/dev/null 2>&1; then
        if ! "$GPG_BIN" --batch --yes --delete-secret-and-public-key "$stale_fpr"; then
          echo "gpg-import: warning — failed to delete stale managed GPG key $stale_fpr from keyring." >&2
        else
          echo "gpg-import: deleted stale managed GPG key $stale_fpr." >&2
        fi
      fi
    fi
  done < "$managed_keys_manifest"
fi

if ! "$GPG_BIN" --import "$GPG_SECRET_PATH"; then
  echo "secrets: gpg import failed for GPG secret." >&2
  exit 1
fi

if [ -z "$first_key_fingerprint" ]; then
  echo "secrets: imported GPG keyring material but could not determine the managed primary fingerprint for ownertrust enforcement." >&2
  exit 1
fi

# Record the managed fingerprint immediately after a successful import so
# this key is tracked for stale-cleanup even if the ownertrust step fails
# (e.g., GnuPG 2.5 + Kyber IPC edge cases on first bootstrap).
mkdir -p "$nucleus_config_dir"
printf '%s\n' "$first_key_fingerprint" > "$managed_keys_manifest"
# Restrict manifest to owner-read-only: the fingerprint identifies the
# managed key; excess visibility could aid key targeting.
chmod 600 "$managed_keys_manifest"

if ! printf '%s:6:\n' "$first_key_fingerprint" | "$GPG_BIN" --import-ownertrust; then
  echo "secrets: warning — failed to enforce ultimate ownertrust for managed primary fingerprint $first_key_fingerprint; key is imported and tracked but trust state may require manual repair." >&2
fi
