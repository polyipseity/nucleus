#!/usr/bin/env bash
# Shell parity tests for src/scripts/lib/load-user-registry.sh.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

LOADER="$REPO_ROOT/src/scripts/lib/load-user-registry.sh"

run_loader() {
  local platform="$1"
  "$LOADER" --platform "$platform" --repo-root "$REPO_ROOT"
}

test_discovers_polyipseity() {
  local registry
  registry="$(run_loader macos)"
  if echo "$registry" | jq -e '.polyipseity' >/dev/null; then
    assert_pass "discovers polyipseity user"
  else
    assert_fail "discovers polyipseity user" "missing polyipseity key"
  fi
}

test_excludes_default_dir() {
  local registry
  registry="$(run_loader macos)"
  if echo "$registry" | jq -e 'has("default")' >/dev/null; then
    assert_fail "excludes default directory" "registry contains reserved directory name"
  else
    assert_pass "excludes default directory"
  fi
}

test_merges_vm_guest_secret_keys() {
  local registry
  registry="$(run_loader macos)"
  if [ "$(echo "$registry" | jq -r '.polyipseity.vmGuest.usernameSecretKey')" = "vm_guest_username" ] \
    && [ "$(echo "$registry" | jq -r '.polyipseity.vmGuest.passwordSecretKey')" = "vm_guest_password" ]; then
    assert_pass "merges vm-guest.json secret-key references"
  else
    assert_fail "merges vm-guest.json secret-key references" "unexpected vmGuest keys"
  fi
}

test_resolves_google_drive_replica_enable_per_platform() {
  local macos_registry windows_registry macos_enable windows_enable
  macos_registry="$(run_loader macos)"
  windows_registry="$(run_loader windows)"
  macos_enable="$(echo "$macos_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "GoogleDrive") | .enable')"
  windows_enable="$(echo "$windows_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "GoogleDrive") | .enable')"
  if [ "$macos_enable" = "false" ] && [ "$windows_enable" = "true" ]; then
    assert_pass "resolves GoogleDrive replica enable per platform"
  else
    assert_fail "resolves GoogleDrive replica enable per platform" "macos=$macos_enable windows=$windows_enable"
  fi
}

test_resolves_icloud_replica_readwrite_per_platform() {
  local macos_registry windows_registry macos_rw windows_rw
  macos_registry="$(run_loader macos)"
  windows_registry="$(run_loader windows)"
  macos_rw="$(echo "$macos_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "iCloud") | .readWrite')"
  windows_rw="$(echo "$windows_registry" | jq -r '.polyipseity.cloudDrives.replicas[] | select(.id == "iCloud") | .readWrite')"
  if [ "$macos_rw" = "true" ] && [ "$windows_rw" = "false" ]; then
    assert_pass "resolves iCloud replica readWrite per platform"
  else
    assert_fail "resolves iCloud replica readWrite per platform" "macos=$macos_rw windows=$windows_rw"
  fi
}

test_exposes_windows_dsc_config_files() {
  local registry
  registry="$(run_loader windows)"
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
  test_merges_vm_guest_secret_keys
  test_resolves_google_drive_replica_enable_per_platform
  test_resolves_icloud_replica_readwrite_per_platform
  test_exposes_windows_dsc_config_files

  echo ""
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
