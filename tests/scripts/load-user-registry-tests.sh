#!/usr/bin/env bash
# Shell parity tests for src/scripts/lib/load-user-registry.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LOADER="$REPO_ROOT/src/scripts/lib/load-user-registry.sh"

run_loader() {
  local host="$1"
  "$LOADER" --host "$host" --repo-root "$REPO_ROOT"
}

test_discovers_polyipseity() {
  local registry
  registry="$(run_loader MacBook)"
  if echo "$registry" | jq -e '.polyipseity' >/dev/null; then
    assert_pass "discovers polyipseity user"
  else
    assert_fail "discovers polyipseity user" "missing polyipseity key"
  fi
}

test_excludes_default_dir() {
  local registry
  registry="$(run_loader MacBook)"
  if echo "$registry" | jq -e 'has("default")' >/dev/null; then
    assert_fail "excludes default directory" "registry contains reserved directory name"
  else
    assert_pass "excludes default directory"
  fi
}

test_merges_is_primary_and_primary_user() {
  local registry
  registry="$(run_loader MacBook)"
  if [ "$(echo "$registry" | jq -r '.polyipseity.isPrimary')" = "true" ] \
    && [ "$(echo "$registry" | jq -r '.primaryUser')" = "polyipseity" ]; then
    assert_pass "merges isPrimary and exposes primaryUser"
  else
    assert_fail "merges isPrimary and exposes primaryUser" "unexpected isPrimary/primaryUser values"
  fi
}

test_merges_vm_guest_secret_keys() {
  local registry
  registry="$(run_loader MacBook)"
  if [ "$(echo "$registry" | jq -r '.polyipseity.vmGuest.usernameSecretKey')" = "vm_guest_username" ] \
    && [ "$(echo "$registry" | jq -r '.polyipseity.vmGuest.passwordSecretKey')" = "vm_guest_password" ]; then
    assert_pass "merges vm-guest.json secret-key references"
  else
    assert_fail "merges vm-guest.json secret-key references" "unexpected vmGuest keys"
  fi
}

test_resolves_google_drive_replica_enable_per_host() {
  local macbook_registry windows_registry macbook_enable windows_enable
  macbook_registry="$(run_loader MacBook)"
  windows_registry="$(run_loader Windows)"
  macbook_enable="$(echo "$macbook_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "GoogleDrive") | .enable')"
  windows_enable="$(echo "$windows_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "GoogleDrive") | .enable')"
  if [ "$macbook_enable" = "false" ] && [ "$windows_enable" = "false" ]; then
    assert_pass "resolves GoogleDrive replica enable per host"
  else
    assert_fail "resolves GoogleDrive replica enable per host" "MacBook=$macbook_enable Windows=$windows_enable"
  fi
}

test_resolves_icloud_replica_readwrite_per_host() {
  local macbook_registry windows_registry macbook_rw windows_rw
  macbook_registry="$(run_loader MacBook)"
  windows_registry="$(run_loader Windows)"
  macbook_rw="$(echo "$macbook_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "iCloud") | .readWrite')"
  windows_rw="$(echo "$windows_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "iCloud") | .readWrite')"
  if [ "$macbook_rw" = "true" ] && [ "$windows_rw" = "false" ]; then
    assert_pass "resolves iCloud replica readWrite per host"
  else
    assert_fail "resolves iCloud replica readWrite per host" "MacBook=$macbook_rw Windows=$windows_rw"
  fi
}

test_exposes_windows_dsc_config_files() {
  local registry
  registry="$(run_loader Windows)"
  if echo "$registry" | jq -e '.polyipseity.dscConfigFiles | index("env.dsc.yml")' >/dev/null \
    && echo "$registry" | jq -e '.polyipseity.dscConfigFiles | index("wallpaper.dsc.yml")' >/dev/null; then
    assert_pass "exposes dscConfigFiles from windows.json"
  else
    assert_fail "exposes dscConfigFiles from windows.json" "missing expected DSC files"
  fi
}

main() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required for load-user-registry-tests.sh" >&2
    exit 1
  }

  test_discovers_polyipseity
  test_excludes_default_dir
  test_merges_is_primary_and_primary_user
  test_merges_vm_guest_secret_keys
  test_resolves_google_drive_replica_enable_per_host
  test_resolves_icloud_replica_readwrite_per_host
  test_exposes_windows_dsc_config_files

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
