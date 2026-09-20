#!/usr/bin/env bash
# Test: verify-secret-decryption rejects a materialized SSH private key that
# OpenSSH cannot read.
#
# A managed key that merely exists is not a key that works: an unparsable file
# makes ssh report "invalid format" and fall back to no authentication, which a
# running agent hides by answering first. The suite drives the real script with
# stub gpg/ssh-to-age and a real ssh-keygen.
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
# kind: generated | garbage | protected | absent
build_case() {
  local _dir="$1" _key="$2" _kind="$3"
  make_fixture "$_dir"
  case "$_kind" in
  generated) ssh-keygen -q -t ed25519 -N '' -f "$_key" >/dev/null ;;
  garbage)
    echo 'this is not a private key' >"$_key"
    chmod 600 "$_key"
    ;;
  protected) ssh-keygen -q -t ed25519 -N 'sekrit' -f "$_key" >/dev/null ;;
  absent) : ;;
  esac
  printf '%s\n' "$_key" >"$_dir/managed-ssh-key-paths"
}

test_readable_key_passes() {
  local _dir _key _out _rc
  _dir="$(mktemp -d)"
  _key="$_dir/ssh_personal_test"
  build_case "$_dir" "$_key" generated
  _out="$(mktemp)"
  _rc="$(run_verify "$_dir" "$_key" "$_out")"
  if [ "$_rc" -eq 0 ] && ! grep -q 'ERROR' "$_out"; then
    assert_pass "a readable managed private key passes verification"
  else
    assert_fail "a readable managed private key passes verification" "exit $_rc: $(head -2 "$_out" | tr '\n' ' ')"
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

test_readable_key_passes
# A managed key must work unattended, so a protected key is a failure — and it
# must be reported, never answered: the script supplies an empty passphrase so
# activation cannot block on a prompt.
expect_rejection "a passphrase-protected managed private key fails verification" protected "not a usable OpenSSH private key"
expect_rejection "an unparsable managed private key fails verification" garbage "not a usable OpenSSH private key"
expect_rejection "a managed private key that is absent fails verification" absent "missing or empty"

finish_tests
