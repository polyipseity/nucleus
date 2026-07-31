#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 11 lockfile-validation must skip when scoped to non-lockfile files.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/11-lockfile-validation.sh"

test_step11_has_explicit_skip_message() {
  # Matches: SKIPPED (no lockfile files to check)
  if grep -q 'SKIPPED (no lockfile files to check)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 11 should have explicit skip message for no lockfile files"
  return 1
}

test_step11_skips_scoped_non_lockfile_files() {
  local _out
  _out="$(bash -c '
    . "'"$REPO_ROOT"'/src/scripts/checks/check-steps/11-lockfile-validation.sh"
    run_11_lockfile_validation true "'"$REPO_ROOT"'" README.md
  ' 2>&1)"
  if echo "$_out" | grep -q 'SKIPPED (no lockfile files to check)'; then
    return 0
  fi
  echo "FAIL: step 11 should skip when scoped to non-lockfile files"
  echo "$_out"
  return 1
}

test_step11_runs_scoped_lockfile() {
  local _out
  _out="$(bash -c '
    . "'"$REPO_ROOT"'/src/scripts/checks/check-steps/11-lockfile-validation.sh"
    run_11_lockfile_validation true "'"$REPO_ROOT"'" src/lockfiles/lockfile.json
  ' 2>&1)"
  if echo "$_out" | grep -q 'SKIPPED (no lockfile files to check)'; then
    echo "FAIL: step 11 should run when scoped to a lockfile file"
    return 1
  fi
  return 0
}

failures=0
for test in test_step11_has_explicit_skip_message test_step11_skips_scoped_non_lockfile_files test_step11_runs_scoped_lockfile; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
