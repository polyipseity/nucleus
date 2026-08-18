#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 16 store-path-arg-usage enforces _X_bin variable command usage

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/16-store-path-arg-usage.sh"

test_step16_declaration_pattern() {
  # The source contains the grep pattern that detects _X_bin="$N" declarations.
  if grep -q '_\[a-z\].*_bin=' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should detect _X_bin=\"\$N\" declarations"
  return 1
}

test_step16_cross_file_search() {
  if grep -q 'all_sh_files' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should search across all shell files (cross-file usage)"
  return 1
}

test_step16_exclusion_list() {
  if grep -q 'configure-gpg-agent' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should exclude configure-gpg-agent.sh (false positive)"
  return 1
}

test_step16_self_exclusion() {
  if grep -q '_self_sh' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should exclude itself from candidate files"
  return 1
}

test_step16_condition_filter() {
  if grep -qE '\[\[?\s+-[zn]\s' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should filter out condition checks ([-z/-n])"
  return 1
}

test_step16_declaration_filter() {
  # The source contains a grep -v pattern that filters out variable declaration lines.
  if grep -q 'a-z_]' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should filter out declaration lines"
  return 1
}

test_step16_error_unused_variable() {
  if grep -q 'declared but never referenced' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should error on unused store-path variables"
  return 1
}

test_step16_error_condition_only() {
  if grep -q 'only used in condition checks' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 16 should error on variables only used in conditions"
  return 1
}

# --- Run all tests ---
_failures=0
for test_func in $(declare -F | grep -o 'test_step16_\w\+'); do
  if ! "$test_func"; then
    _failures=$((_failures + 1))
  fi
done

if [ "$_failures" -gt 0 ]; then
  echo "FAILED: $_failures test(s) failed"
  exit 1
fi
echo "All step 16 shell tests passed."
