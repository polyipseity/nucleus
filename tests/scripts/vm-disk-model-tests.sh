#!/usr/bin/env bash
# Identity derivation parity tests for the VM disk model. The deterministic
# UUID/MAC derivations (Nix source of truth: src/modules/lib/vm-identity.nix,
# consumed by src/hosts/MacBook/vms.nix) are recomputed in shell with
# printf+sha256sum and pinned against the same known vectors as
# tests/modules/vm-setup-tests.nix, so the shell twin (P1, src/scripts/lib/
# vm.sh) cannot drift from Nix. Later phases extend this file with sandboxed
# qemu-img disk-model tests (overlay creation, backing-file paths, resize).
#
# Run with: bash tests/scripts/vm-disk-model-tests.sh

_failures=0

mk_uuid() { # mk_uuid <id> — 8-4-4-4-12 UUID from the SHA-256 of the id
  local _id="$1" _h
  _h=$(printf '%s' "$_id" | sha256sum | cut -d' ' -f1)
  printf '%s-%s-%s-%s-%s' "${_h:0:8}" "${_h:8:4}" "${_h:12:4}" "${_h:16:4}" "${_h:20:12}"
}

mk_mac_address() { # mk_mac_address <id> <prefix> — prefix + 5 hex octets from the SHA-256 of "mac:<id>"
  local _id="$1" _prefix="$2" _h
  _h=$(printf '%s' "mac:$_id" | sha256sum | cut -d' ' -f1)
  printf '%s:%s:%s:%s:%s:%s' "$_prefix" "${_h:0:2}" "${_h:2:2}" "${_h:4:2}" "${_h:6:2}" "${_h:8:2}"
}

assert_eq() { # assert_eq <expected> <actual> <label>
  local _expected="$1" _actual="$2" _label="$3"
  if [ "$_expected" != "$_actual" ]; then
    echo "FAIL: $_label: expected '$_expected', got '$_actual'"
    _failures=$((_failures + 1))
  fi
}

test_uuid_vectors() {
  assert_eq "6d612a86-bee4-b0a6-59b8-b3affd6f1fbc" "$(mk_uuid Android)" "UUID Android"
  assert_eq "ac92e761-3044-a456-82e8-cf01eb2471d0" "$(mk_uuid MacBook)" "UUID MacBook"
  assert_eq "cdf51633-aff8-ffbd-4feb-c43ff4de3f1c" "$(mk_uuid NixOS)" "UUID NixOS"
  assert_eq "d598026a-9cbc-6050-5f13-8ce53ac78088" "$(mk_uuid Windows)" "UUID Windows"
}

test_mac_vectors() {
  assert_eq "52:dd:a9:e1:f8:66" "$(mk_mac_address Android 52)" "MAC Android"
  assert_eq "52:d2:6b:37:60:34" "$(mk_mac_address MacBook 52)" "MAC MacBook"
}

test_deterministic() {
  local _first _second
  _first=$(mk_uuid Android)
  _second=$(mk_uuid Android)
  assert_eq "$_first" "$_second" "UUID derivation is deterministic"
}

test_uuid_vectors
test_mac_vectors
test_deterministic

if [ "$_failures" -eq 0 ]; then
  echo "vm-disk-model-tests: all checks passed"
  exit 0
fi
echo "vm-disk-model-tests: $_failures check(s) failed" >&2
exit 1
