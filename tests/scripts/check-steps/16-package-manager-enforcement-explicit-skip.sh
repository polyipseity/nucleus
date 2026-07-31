#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 16 package-manager-enforcement must skip when scoped to non-shell files.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/16-package-manager-enforcement.sh"

test_step16_has_explicit_skip_message() {
  # Matches: SKIPPED (no shell files to check)
  if grep -q 'SKIPPED (no shell files to check)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should have explicit skip message for no shell files"
  return 1
}

test_step16_skips_scoped_non_shell_files() {
  local _out
  _out="$(bash -c '
    . "'"$REPO_ROOT"'/src/scripts/checks/check-steps/16-package-manager-enforcement.sh"
    run_16_package_manager_enforcement true "'"$REPO_ROOT"'" README.md
  ' 2>&1)"
  if echo "$_out" | grep -q 'SKIPPED (no shell files to check)'; then
    return 0
  fi
  echo "FAIL: step 16 should skip when scoped to non-shell files"
  echo "$_out"
  return 1
}

test_step16_runs_scoped_shell_file() {
  local _out
  _out="$(bash -c '
    . "'"$REPO_ROOT"'/src/scripts/checks/check-steps/16-package-manager-enforcement.sh"
    run_16_package_manager_enforcement true "'"$REPO_ROOT"'" src/modules/core.nix
  ' 2>&1)"
  if echo "$_out" | grep -q 'SKIPPED (no shell files to check)'; then
    echo "FAIL: step 16 should run when scoped to a shell/nix/ps1 file"
    return 1
  fi
  return 0
}

failures=0
for test in test_step16_has_explicit_skip_message test_step16_skips_scoped_non_shell_files test_step16_runs_scoped_shell_file; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
