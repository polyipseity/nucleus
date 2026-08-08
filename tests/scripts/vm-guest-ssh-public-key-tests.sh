#!/usr/bin/env bash
# Guest SSH public key resolution tests for vm_resolve_guest_ssh_public_key.
# Reads paths from src/modules/vm-guest-ssh-public-key-paths.json (SSOT).
#
# Run with: bash tests/scripts/vm-guest-ssh-public-key-tests.sh

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

_failures=0
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

assert_eq() {
  local _expected="$1" _actual="$2" _label="$3"
  if [ "$_expected" != "$_actual" ]; then
    echo "FAIL: $_label: expected '$_expected', got '$_actual'"
    _failures=$((_failures + 1))
  fi
}

assert_fail() {
  local _label="$1"
  shift
  if "$@"; then
    echo "FAIL: $_label: expected failure"
    _failures=$((_failures + 1))
  fi
}

assert_ok() {
  local _label="$1"
  shift
  if ! "$@"; then
    echo "FAIL: $_label: expected success"
    _failures=$((_failures + 1))
  fi
}

_ssh_home="$_tmp/home"
_ssh_dir="$_ssh_home/.ssh"
mkdir -p "$_ssh_dir"
export HOME="$_ssh_home"

_test_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTests nucleus-vm-guest-ssh-test'
_personal_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPersonalKeyForTests nucleus-personal'

printf '%s\n' "$_test_key" > "$_ssh_dir/id_ed25519.pub"
printf '%s\n' "$_personal_key" > "$_ssh_dir/ssh_personal_testuser.pub"

_res="$(vm_resolve_guest_ssh_public_key 'testuser' "$REPO_ROOT")"
assert_eq "$_test_key" "$_res" 'static id_ed25519.pub preferred over ssh_personal template'

rm -f "$_ssh_dir/id_ed25519.pub"
_res="$(vm_resolve_guest_ssh_public_key 'testuser' "$REPO_ROOT")"
assert_eq "$_personal_key" "$_res" 'ssh_personal_testuser.pub resolved when static keys absent'

rm -f "$_ssh_dir/ssh_personal_testuser.pub"
assert_fail 'no keys returns failure' vm_resolve_guest_ssh_public_key 'testuser' "$REPO_ROOT"

assert_fail 'empty username skips templates when only personal key exists' vm_resolve_guest_ssh_public_key '' "$REPO_ROOT"

printf '%s\n' "$_test_key" > "$_ssh_dir/id_ed25519.pub"
assert_ok 'empty username still resolves static keys' vm_resolve_guest_ssh_public_key '' "$REPO_ROOT"

if [ "$_failures" -eq 0 ]; then
  echo 'PASS: vm-guest-ssh-public-key-tests'
  exit 0
fi

echo "FAIL: $_failures test(s) failed"
exit 1
