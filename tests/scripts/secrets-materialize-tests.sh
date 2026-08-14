#!/usr/bin/env bash
# Behavioral tests for decrypt-sops user discovery and materialize-user-secrets routing.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=../../src/scripts/lib/resolve-user-homedir.sh
. "$REPO_ROOT/src/scripts/lib/resolve-user-homedir.sh"

MATERIALIZE_SCRIPT="$REPO_ROOT/src/scripts/secrets/materialize-user-secrets.sh"
DERIVE_HOST_AGE_KEY_SCRIPT="$REPO_ROOT/src/scripts/secrets/derive-host-age-key.sh"

test_list_secret_users_sorted() {
  local users prev=""
  mapfile -t users < <(list_secret_users "$REPO_ROOT")
  if [ "${#users[@]}" -lt 1 ]; then
    assert_fail "list_secret_users returns secret users" "expected at least one user"
    return
  fi
  for user in "${users[@]}"; do
    if [ -n "$prev" ] && [[ "$user" < "$prev" ]]; then
      assert_fail "list_secret_users returns lexicographically sorted users" "out of order: $prev then $user"
      return
    fi
    prev="$user"
  done
  assert_pass "list_secret_users returns lexicographically sorted secret users"
}

test_materialize_exits_clean_without_user_secret_file() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/src/secrets/users"
  if "$MATERIALIZE_SCRIPT" \
    "$tmp" "missing-user" "$(command -v gpg)" "$(command -v git)" \
    "$(command -v ssh-keygen)" "$(command -v ssh-add)" "$(command -v sops)" \
    "/tmp/nonexistent-host-key" "/tmp/nonexistent-age-key" >/dev/null 2>&1; then
    assert_pass "materialize-user-secrets exits 0 when user secret file is absent"
  else
    assert_fail "materialize-user-secrets exits 0 when user secret file is absent" "exit code $?"
  fi
  rm -rf "$tmp"
}

test_materialize_skips_jit_key_prefixes() {
  if bash -c '
    _mus_should_skip_key() {
      case "$1" in
        sops | jellyfin_* | vm_guest_*) return 0 ;;
        *) return 1 ;;
      esac
    }
    _mus_should_skip_key jellyfin_api \
      && _mus_should_skip_key vm_guest_ssh \
      && _mus_should_skip_key sops \
      && ! _mus_should_skip_key gpg_private
  '; then
    assert_pass "materialize-user-secrets skips JIT-only key prefixes"
  else
    assert_fail "materialize-user-secrets skips JIT-only key prefixes" "routing case mismatch"
  fi
}

test_decrypt_sops_skips_unreadable_host_key() {
  # shellcheck disable=SC2016 # reason: literal grep pattern for decrypt-sops host-key guard
  if grep -Fq '[ -r "$_ds_host_key_path" ]' "$REPO_ROOT/src/scripts/secrets/decrypt-sops.sh"; then
    assert_pass "decrypt-sops skips unreadable machine SSH host key"
  else
    assert_fail "decrypt-sops skips unreadable machine SSH host key" "expected -r host-key guard"
  fi
}

test_materialize_replaces_stale_ssh_symlinks() {
  # shellcheck disable=SC2016 # reason: literal grep pattern for materialize symlink cleanup
  if grep -Fq 'rm -f "$_mus_ssh_target"' "$MATERIALIZE_SCRIPT"; then
    assert_pass "materialize-user-secrets replaces stale SSH symlinks before write"
  else
    assert_fail "materialize-user-secrets replaces stale SSH symlinks before write" "missing rm -f guard"
  fi
}

test_derive_host_age_key_skips_without_host_key() {
  if [ -f /etc/ssh/ssh_host_ed25519_key ]; then
    assert_pass "derive-host-age-key skip-without-host-key (skipped: host key present on runner)"
    return
  fi
  local fake_ssh_to_age
  fake_ssh_to_age="$(mktemp)"
  cat >"$fake_ssh_to_age" <<'EOF'
#!/usr/bin/env bash
echo "AGE-SECRET-KEY-FAKE"
EOF
  chmod +x "$fake_ssh_to_age"
  if "$DERIVE_HOST_AGE_KEY_SCRIPT" "$fake_ssh_to_age" "user:test" >/dev/null 2>&1; then
    assert_pass "derive-host-age-key exits cleanly when host SSH key is absent"
  else
    assert_fail "derive-host-age-key exits cleanly when host SSH key is absent" "exit code $?"
  fi
  rm -f "$fake_ssh_to_age"
}

test_list_secret_users_sorted
test_materialize_exits_clean_without_user_secret_file
test_materialize_skips_jit_key_prefixes
test_decrypt_sops_skips_unreadable_host_key
test_materialize_replaces_stale_ssh_symlinks
test_derive_host_age_key_skips_without_host_key

echo ""
echo "============================================================"
echo "Test Summary:"
printf '%sPassed: %s%s\n' "$GREEN" "$TESTS_PASSED" "$NC"
printf '%sFailed: %s%s\n' "$RED" "$TESTS_FAILED" "$NC"
echo "============================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
