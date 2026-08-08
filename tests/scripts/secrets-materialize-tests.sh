#!/usr/bin/env bash
# Tests decrypt-sops.sh user discovery and materialize-user-secrets.sh key routing.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=../../src/scripts/lib/resolve-user-homedir.sh
. "$REPO_ROOT/src/scripts/lib/resolve-user-homedir.sh"

test_list_secret_users_sorted() {
  local users
  mapfile -t users < <(list_secret_users "$REPO_ROOT")
  if [ "${#users[@]}" -ge 1 ] && [ "${users[0]}" = "polyipseity" ]; then
    assert_pass "list_secret_users returns sorted secret users"
  else
    assert_fail "list_secret_users returns sorted secret users" "expected polyipseity first, got: ${users[*]:-}"
  fi
}

test_decrypt_sops_script_exists() {
  if [ -x "$REPO_ROOT/src/scripts/secrets/decrypt-sops.sh" ]; then
    assert_pass "decrypt-sops.sh is executable"
  else
    assert_fail "decrypt-sops.sh is executable" "missing or not executable"
  fi
}

test_materialize_script_exists() {
  if [ -x "$REPO_ROOT/src/scripts/secrets/materialize-user-secrets.sh" ]; then
    assert_pass "materialize-user-secrets.sh is executable"
  else
    assert_fail "materialize-user-secrets.sh is executable" "missing or not executable"
  fi
}

test_materialize_skips_jit_keys() {
  local script_text
  script_text="$(<"$REPO_ROOT/src/scripts/secrets/materialize-user-secrets.sh")"
  if [[ "$script_text" == *"jellyfin_*"* && "$script_text" == *"vm_guest_*"* ]]; then
    assert_pass "materialize-user-secrets skips JIT-only key prefixes"
  else
    assert_fail "materialize-user-secrets skips JIT-only key prefixes" "expected jellyfin_* and vm_guest_* skip cases"
  fi
}

test_derive_host_age_key_uses_shared_group() {
  local script_text
  script_text="$(<"$REPO_ROOT/src/scripts/secrets/derive-host-age-key.sh")"
  if [[ "$script_text" == *'group:*)'* && "$script_text" == *'user:*)'* && "$script_text" == *"chmod 0640"* && "$script_text" == *"chmod 0600"* ]]; then
    assert_pass "derive-host-age-key supports user and group owner specs"
  else
    assert_fail "derive-host-age-key supports user and group owner specs" "expected user:/group: owner specs with mode 0600/0640"
  fi
}

test_list_secret_users_sorted
test_decrypt_sops_script_exists
test_materialize_script_exists
test_materialize_skips_jit_keys
test_derive_host_age_key_uses_shared_group

echo ""
echo "============================================================"
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
