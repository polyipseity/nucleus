#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 13 repository-policy must enforce dummy-key registry uniformity

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/13-repository-policy.sh"
REGISTRY_FILE="$REPO_ROOT/src/modules/dummy-keys.json"

test_step13_dummy_key_registry_read() {
  if grep -q 'dummy-keys.json' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 13 should read the dummy-key registry from dummy-keys.json"
  return 1
}

test_step13_dummy_key_literal_pattern() {
  # Matches: the rule comment sk-[A-Za-z0-9]{4,}
  if grep -q 'sk-\[A-Za-z0-9\]{4,}' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 13 should target sk-[A-Za-z0-9]{4,} API key literals"
  return 1
}

test_step13_dummy_key_error_path() {
  if grep -q 'unregistered dummy API key literal' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 13 should error on unregistered dummy API key literals"
  return 1
}

test_step13_dummy_key_registered_value() {
  if grep -q 'sk-nucleus-dummy-litellm' "$REGISTRY_FILE"; then
    return 0
  fi
  echo "FAIL: dummy-key registry should register the sk-nucleus-dummy-litellm value"
  return 1
}

failures=0
for test in \
  test_step13_dummy_key_registry_read \
  test_step13_dummy_key_literal_pattern \
  test_step13_dummy_key_error_path \
  test_step13_dummy_key_registered_value; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
