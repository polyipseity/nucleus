#!/usr/bin/env bash
# Managed macOS preference domain GC.
# Expects env vars: NIX_STORE_BIN, MANAGED_PREF_DOMAINS
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

# Verify Nix store integrity before running destructive preference cleanup.
# If verification fails we skip purge so an unrelated store issue cannot be
# compounded by deleting user preference state in the same maintenance run.
if ! "$NIX_STORE_BIN" --verify --check-contents >/dev/null 2>&1; then
  warn "store integrity check failed; skipping managed preference purge for safety."
  exit 0
fi

prefs_root="$HOME/Library/Preferences"
byhost_root="$prefs_root/ByHost"

purge_domain_variants() {
  domain="$1"
  domain_variants="$domain"

  if [ "$domain" = "NSGlobalDomain" ]; then
    domain_variants="$domain .GlobalPreferences"
  fi

  for variant in $domain_variants; do
    # Clear in-memory registration first, then remove persisted payloads.
    # check-suppress:suppression_doc: preference key may not exist; defaults delete exits 1 for missing keys (graceful no-op on first run).
    /usr/bin/defaults delete "$variant" >/dev/null 2>&1 || true

    if [ -d "$prefs_root" ]; then
      /usr/bin/find "$prefs_root" -maxdepth 1 -type f -name "$variant.plist" -delete
    fi

    if [ -d "$byhost_root" ]; then
      /usr/bin/find "$byhost_root" -maxdepth 1 -type f -name "$variant.*.plist" -delete
    fi
  done
}

for domain in $MANAGED_PREF_DOMAINS; do
  purge_domain_variants "$domain"
done
