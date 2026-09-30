#!/usr/bin/env bash
# Test: verify-secret-decryption accepts every valid OpenSSH private key and
# rejects what is not one.
#
# The check exists because an unparsable private key makes ssh report "invalid
# format" and fall back to no authentication, which a running agent hides by
# answering first.  Validity is the whole contract: a passphrase-protected key is
# a valid key, so it passes.  The suite drives the real script with stub
# gpg/ssh-to-age and a real ssh-keygen.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
VERIFY_SCRIPT="$REPO_ROOT/src/scripts/secrets/verify-secret-decryption.sh"

require_command jq "jq is required to drive verify-secret-decryption"
require_command ssh-keygen "ssh-keygen is required to materialize fixture keys"

# make_fixture <dir> — build a fixture tree whose only variable is the private
# key. Empty GPG-fingerprint and SOPS manifests keep checks 2-4 on the paths that
# need no real keyring, and the two stubs answer the probes those checks make.
make_fixture() {
  local _dir="$1"
  mkdir -p "$_dir/bin" "$_dir/gnupg"
  printf '%s\n' '#!/bin/sh' 'echo sec:u:1:DEADBEEF' >"$_dir/bin/gpg"
  printf '%s\n' '#!/bin/sh' 'echo age1nucleustest' >"$_dir/bin/ssh-to-age"
  chmod +x "$_dir/bin/gpg" "$_dir/bin/ssh-to-age"
  echo 'DEADBEEF' >"$_dir/managed-gpg-keys"
  echo 'git identity' >"$_dir/git-identity"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLE fixture' >"$_dir/ssh_personal.pub"
  echo 'adopted' >"$_dir/managed-ssh-keys"
  echo '[]' >"$_dir/sops.json"
}

# run_verify <fixture-dir> <private-key-path> <output-file> — print the exit code.
run_verify() {
  local _dir="$1" _private_key="$2" _out="$3" _rc=0
  "$VERIFY_SCRIPT" \
    "$(command -v jq)" \
    "$_dir/bin/gpg" \
    "$_dir/bin/ssh-to-age" \
    "$(command -v ssh-keygen)" \
    "$_dir/gnupg" \
    "$(cat "$_dir/sops.json")" \
    "$_dir/git-identity" \
    "$_private_key" \
    "$_dir/ssh_personal.pub" \
    "$_dir/managed-gpg-keys" \
    "$_dir/managed-ssh-key-paths" \
    "$_dir/managed-ssh-keys" >"$_out" 2>&1 || _rc=$?
  printf '%s\n' "$_rc"
}

# fixture <dir> <private-key-path> <private-key-contents-kind>
# kind: generated | protected | public | truncated | garbage | absent
build_case() {
  local _dir="$1" _key="$2" _kind="$3"
  make_fixture "$_dir"
  case "$_kind" in
  generated) ssh-keygen -q -t ed25519 -N '' -f "$_key" >/dev/null ;;
  protected) ssh-keygen -q -t ed25519 -N 'sekrit' -f "$_key" >/dev/null ;;
  public)
    # A bare public key standing where a private key belongs.  ssh-keygen -l
    # fingerprints it happily, so only the PEM header check rejects it.
    ssh-keygen -q -t ed25519 -N '' -f "$_key" >/dev/null
    ssh-keygen -y -f "$_key" >"$_key.pub"
    mv "$_key.pub" "$_key"
    ;;
  truncated)
    # A valid private key cut mid-way through its base64 body, so the PEM header
    # still reads correctly and only ssh-keygen -l can reject it.  Derived at
    # runtime from a real key rather than written as a literal PEM block, which
    # the private-key detector in prek flags.
    #
    # The cut has to land inside the first base64 line: that line already holds
    # the whole ed25519 public blob, so dropping whole trailing lines leaves a
    # file ssh-keygen still reads.
    ssh-keygen -q -t ed25519 -N '' -f "$_key" >/dev/null
    {
      sed -n '1p' "$_key"
      sed -n '2p' "$_key" | cut -c1-40
    } >"$_key.trunc"
    mv "$_key.trunc" "$_key"
    chmod 600 "$_key"
    ;;
  garbage)
    echo 'this is not a private key' >"$_key"
    chmod 600 "$_key"
    ;;
  absent) : ;;
  esac
  printf '%s\n' "$_key" >"$_dir/managed-ssh-key-paths"
}

# expect_acceptance <name> <kind> — the script must exit 0 without an ERROR.
expect_acceptance() {
  local _name="$1" _kind="$2"
  local _dir _key _out _rc
  _dir="$(mktemp -d)"
  _key="$_dir/ssh_personal_test"
  build_case "$_dir" "$_key" "$_kind"
  _out="$(mktemp)"
  _rc="$(run_verify "$_dir" "$_key" "$_out")"
  if [ "$_rc" -ne 0 ]; then
    assert_fail "$_name" "rejected a valid key: $(head -2 "$_out" | tr '\n' ' ')"
  elif grep -q 'ERROR' "$_out"; then
    assert_fail "$_name" "reported an error: $(head -2 "$_out" | tr '\n' ' ')"
  else
    assert_pass "$_name"
  fi
  rm -f "$_out"
  rm -rf "$_dir"
}

# expect_rejection <name> <kind> <expected-substring>
expect_rejection() {
  local _name="$1" _kind="$2" _expected_text="$3"
  local _dir _key _out _rc
  _dir="$(mktemp -d)"
  _key="$_dir/ssh_personal_test"
  build_case "$_dir" "$_key" "$_kind"
  _out="$(mktemp)"
  _rc="$(run_verify "$_dir" "$_key" "$_out")"
  if [ "$_rc" -eq 0 ]; then
    assert_fail "$_name" "verification passed a key it must reject"
  elif ! grep -qF -- "$_expected_text" "$_out"; then
    assert_fail "$_name" "output does not mention '$_expected_text': $(head -2 "$_out" | tr '\n' ' ')"
  else
    assert_pass "$_name"
  fi
  rm -f "$_out"
  rm -rf "$_dir"
}

# The regression that made -l unusable on the real host.  materialize-user-secrets
# writes <key>.pub next to <key>, and ssh-keygen -l -f <key> prefers that sibling:
# it reports the PUBLIC key's fingerprint and never opens the private key.  A
# corrupt private key beside a valid .pub therefore reads as fine.  Probing
# through a sibling-free symlink is what makes the check real.
test_shadowing_public_sibling_cannot_mask_a_broken_private_key() {
  local _dir _key _out _rc
  _dir="$(mktemp -d)"
  _key="$_dir/ssh_personal_test"
  build_case "$_dir" "$_key" truncated
  # A valid public key derived from a different, intact key, at the path ssh-keygen
  # would prefer over the private one.
  ssh-keygen -q -t ed25519 -N '' -f "$_dir/other" >/dev/null
  cp "$_dir/other.pub" "$_key.pub"
  _out="$(mktemp)"
  _rc="$(run_verify "$_dir" "$_key" "$_out")"
  if [ "$_rc" -eq 0 ]; then
    assert_fail "a broken private key is rejected even with a valid .pub sibling" "the .pub shadowed the private key; verification passed"
  elif ! grep -qF 'not a valid OpenSSH private key' "$_out"; then
    assert_fail "a broken private key is rejected even with a valid .pub sibling" "output does not name the failure: $(head -2 "$_out" | tr '\n' ' ')"
  else
    assert_pass "a broken private key is rejected even with a valid .pub sibling"
  fi
  rm -f "$_out"
  rm -rf "$_dir"
}

expect_acceptance "a readable managed private key passes verification" generated
# A passphrase-protected key is a valid key.  Rejecting it meant demanding a
# key that works with no passphrase, which is a property of the deployment, not
# of the key, and the agent supplies it through AddKeysToAgent/UseKeychain.
expect_acceptance "a passphrase-protected managed private key passes verification" protected
expect_rejection "an unparsable managed private key fails verification" garbage "not a valid OpenSSH private key"
# Header present, body unreadable: only the ssh-keygen -l check catches this.
expect_rejection "a truncated private key body fails verification" truncated "ssh-keygen -l could not read it"
# The gap a bare -l check leaves open: a public key parses and fingerprints, so
# only the PEM header check rejects it.
expect_rejection "a public key in place of a private key fails verification" public "not a valid OpenSSH private key"
expect_rejection "a managed private key that is absent fails verification" absent "missing or empty"

test_shadowing_public_sibling_cannot_mask_a_broken_private_key
finish_tests
