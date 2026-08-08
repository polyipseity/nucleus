#!/usr/bin/env bash
# shellcheck source=./test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLY_SH="$REPO_ROOT/src/scripts/apply.sh"
MAC_ACTIVATION="$REPO_ROOT/src/hosts/MacBook/activation.nix"
NIXOS_JELLYFIN="$REPO_ROOT/src/hosts/NixOS/jellyfin.nix"

test_apply_references_jellyfin_sync() {
  if grep -Fq 'src/scripts/services/jellyfin-sync.sh' "$APPLY_SH"; then
    assert_pass "apply.sh references jellyfin-sync.sh"
  else
    assert_fail "apply.sh references jellyfin-sync.sh" "missing jellyfin-sync invocation"
  fi
}

test_macbook_activation_does_not_invoke_jellyfin_sync() {
  if grep -Fq 'jellyfin-sync.sh' "$MAC_ACTIVATION"; then
    assert_fail "MacBook activation must not invoke jellyfin-sync.sh" "found jellyfin-sync in activation.nix"
  else
    assert_pass "MacBook activation does not invoke jellyfin-sync.sh"
  fi
}

test_nixos_jellyfin_module_does_not_invoke_jellyfin_sync() {
  if grep -Fq 'jellyfin-sync.sh' "$NIXOS_JELLYFIN"; then
    assert_fail "NixOS jellyfin.nix must not invoke jellyfin-sync.sh" "found jellyfin-sync in jellyfin.nix"
  else
    assert_pass "NixOS jellyfin.nix does not invoke jellyfin-sync.sh"
  fi
}

test_apply_references_jellyfin_sync
test_macbook_activation_does_not_invoke_jellyfin_sync
test_nixos_jellyfin_module_does_not_invoke_jellyfin_sync
