#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 9 schema-validation must enforce $schema presence (Spec G)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/09-schema-validation.sh"

test_step09_has_missing_schema_check() {
  # Matches: error "Missing \$schema in $_f"
  # shellcheck disable=SC2016 # reason: literal $schema in grep pattern
  if grep -q 'Missing.*$schema' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 should check for missing \$schema"
  return 1
}

test_step09_has_format_check() {
  # Matches: error "Invalid \$schema in $_f: must be a non-empty string"
  # shellcheck disable=SC2016 # reason: literal $schema in grep pattern
  if grep -q 'Invalid.*$schema.*non-empty' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 should check for invalid (empty) \$schema format"
  return 1
}

test_step09_has_exception_list() {
  # Matches: *.schema.json|*/vendor/*|*/secrets/* etc.
  if grep -q 'schema.json.*vendor.*secrets' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 should have exception list for \$schema check"
  return 1
}

test_step09_github_exceptions_handle_dot_prefix() {
  # Matches: find . yields ./.github/... so exception globs must be *-prefixed
  if grep -q '\*/\.github/workflows/\*' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 .github exception globs should match ./-prefixed paths"
  return 1
}

test_step09_exempts_app_configs_without_schema() {
  # Matches: app-owned formats (vscode, camilladsp, agents/hooks, litellm, sops) in exception list
  if grep -q 'configs/vscode.*configs/camilladsp.*configs/agents/hooks.*sops' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 should exempt app-owned config formats without published schemas"
  return 1
}

test_step09_missing_schema_errors_counted() {
  # Matches: _jsonschema_errors=$((_jsonschema_errors + _missing_schema))
  if grep -q '_jsonschema_errors.*_missing_schema' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 9 should add missing \$schema errors to total"
  return 1
}

failures=0
for test in test_step09_has_missing_schema_check test_step09_has_format_check test_step09_has_exception_list test_step09_github_exceptions_handle_dot_prefix test_step09_exempts_app_configs_without_schema test_step09_missing_schema_errors_counted; do
  if ! $test; then
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ] || exit 1
