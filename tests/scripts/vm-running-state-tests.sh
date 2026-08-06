#!/usr/bin/env bash
# Unit tests for VM running vs registered hypervisor name parsing.
#
# Run with: bash tests/scripts/vm-running-state-tests.sh

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../src/scripts/lib/lib.sh
. "$REPO_ROOT/src/scripts/lib/lib.sh"
# shellcheck source=../../src/scripts/lib/vm.sh
. "$REPO_ROOT/src/scripts/lib/vm.sh"

_failures=0

assert_eq() {
  local _expected="$1" _actual="$2" _label="$3"
  if [ "$_expected" != "$_actual" ]; then
    echo "FAIL: $_label: expected '$_expected', got '$_actual'"
    _failures=$((_failures + 1))
  fi
}

assert_lines_eq() {
  local _expected="$1" _actual="$2" _label="$3"
  local _norm_expected _norm_actual
  _norm_expected="$(printf '%s\n' "$_expected" | sed '/^$/d' | sort)"
  _norm_actual="$(printf '%s\n' "$_actual" | sed '/^$/d' | sort)"
  if [ "$_norm_expected" != "$_norm_actual" ]; then
    echo "FAIL: $_label"
    echo "  expected:"
    printf '%s\n' "$_norm_expected" | sed 's/^/    /'
    echo "  actual:"
    printf '%s\n' "$_norm_actual" | sed 's/^/    /'
    _failures=$((_failures + 1))
  fi
}

_utm_fixture='UUID                                 Status   Name
D77A861B-61DD-483A-BA09-D647C77EB77A stopped  NixOS
EADB0899-8B20-48B9-BD23-B179E3C258B3 started  Android
FADB0899-8B20-48B9-BD23-B179E3C258B4 paused   Windows'

_registered="$(printf '%s\n' "$_utm_fixture" | vm_parse_utm_registered_names_from_list)"
assert_lines_eq $'Android\nNixOS\nWindows' "$_registered" "utm registered names include stopped VMs"

_running="$(printf '%s\n' "$_utm_fixture" | vm_parse_utm_running_names_from_list)"
assert_lines_eq $'Android\nWindows' "$_running" "utm running names exclude stopped VMs"

_tart_fixture='[
  {"Name":"macos-local","Running":false,"State":"stopped","Source":"local"},
  {"Name":"android-oci","Running":false,"State":"stopped","Source":"OCI"},
  {"Name":"macos-live","Running":true,"State":"running","Source":"local"}
]'

_tart_registered="$(printf '%s\n' 'Source Name
local macos-local
OCI android-oci
local macos-live' | vm_parse_tart_registered_names_from_list)"
assert_lines_eq $'android-oci\nmacos-live\nmacos-local' "$_tart_registered" "tart registered names from table"

_tart_running="$(printf '%s\n' "$_tart_fixture" | vm_parse_tart_running_names_from_json)"
assert_lines_eq 'macos-live' "$_tart_running" "tart running names from JSON"

if [ "$_failures" -eq 0 ]; then
  echo "PASS: vm-running-state-tests"
  exit 0
fi

echo "FAIL: $_failures test(s) failed"
exit 1
