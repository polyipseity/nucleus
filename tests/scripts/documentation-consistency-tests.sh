#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=all
# Documentation consistency tests for the step-runner framework.
# Verify that usage strings, header comments, and help output are consistent.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

failures=0

# --- Header comments ---

test_check_sh_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/scripts/check.sh"; then
    return 0
  fi
  echo "FAIL: scripts/check.sh should mention --skip-steps"
  return 1
}

test_check_sh_no_format() {
  if grep -qv -- '--format' "$REPO_ROOT/scripts/check.sh"; then
    return 0
  fi
  echo "FAIL: scripts/check.sh should NOT contain --format"
  return 1
}

test_check_ps1_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/scripts/check.ps1"; then
    return 0
  fi
  echo "FAIL: scripts/check.ps1 should mention --skip-steps"
  return 1
}

test_check_ps1_no_format() {
  if grep -qv -- '--format' "$REPO_ROOT/scripts/check.ps1"; then
    return 0
  fi
  echo "FAIL: scripts/check.ps1 should NOT contain --format"
  return 1
}

test_test_sh_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/scripts/test.sh"; then
    return 0
  fi
  echo "FAIL: scripts/test.sh should mention --skip-steps"
  return 1
}

test_test_sh_no_skip_system_build() {
  if grep -qv -- '--skip-system-build' "$REPO_ROOT/scripts/test.sh"; then
    return 0
  fi
  echo "FAIL: scripts/test.sh should NOT contain --skip-system-build"
  return 1
}

test_test_ps1_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/scripts/test.ps1"; then
    return 0
  fi
  echo "FAIL: scripts/test.ps1 should mention --skip-steps"
  return 1
}

test_test_ps1_no_skip_system_build() {
  if grep -qv -- '--skip-system-build' "$REPO_ROOT/scripts/test.ps1"; then
    return 0
  fi
  echo "FAIL: scripts/test.ps1 should NOT contain --skip-system-build"
  return 1
}

# --- Framework library usage functions ---

test_check_lib_usage_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/src/scripts/checks/check-lib.sh"; then
    return 0
  fi
  echo "FAIL: src/scripts/checks/check-lib.sh usage should mention --skip-steps"
  return 1
}

test_check_lib_usage_no_format() {
  if grep -qv -- '--format' "$REPO_ROOT/src/scripts/checks/check-lib.sh"; then
    return 0
  fi
  echo "FAIL: src/scripts/checks/check-lib.sh usage should NOT contain --format"
  return 1
}

test_check_lib_ps1_usage_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/src/scripts/checks/check-lib.ps1"; then
    return 0
  fi
  echo "FAIL: src/scripts/checks/check-lib.ps1 usage should mention --skip-steps"
  return 1
}

test_test_lib_usage_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/src/scripts/tests/test-lib.sh"; then
    return 0
  fi
  echo "FAIL: src/scripts/tests/test-lib.sh usage should mention --skip-steps"
  return 1
}

test_test_lib_usage_no_skip_system_build() {
  if grep -qv -- '--skip-system-build' "$REPO_ROOT/src/scripts/tests/test-lib.sh"; then
    return 0
  fi
  echo "FAIL: src/scripts/tests/test-lib.sh usage should NOT contain --skip-system-build"
  return 1
}

test_test_lib_ps1_usage_has_skip_steps() {
  if grep -q -- '--skip-steps' "$REPO_ROOT/src/scripts/tests/test-lib.ps1"; then
    return 0
  fi
  echo "FAIL: src/scripts/tests/test-lib.ps1 usage should mention --skip-steps"
  return 1
}

test_test_lib_ps1_usage_no_skip_system_build() {
  if grep -qv -- '--skip-system-build' "$REPO_ROOT/src/scripts/tests/test-lib.ps1"; then
    return 0
  fi
  echo "FAIL: src/scripts/tests/test-lib.ps1 usage should NOT contain --skip-system-build"
  return 1
}

# --- Runtime help output tests ---

test_check_help_has_skip_steps() {
  local output
  output=$("$REPO_ROOT/scripts/check.sh" --help 2>&1)
  if echo "$output" | grep -q -- '--skip-steps'; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --help output should mention --skip-steps"
  return 1
}

test_check_help_no_format() {
  local output
  output=$("$REPO_ROOT/scripts/check.sh" --help 2>&1)
  if echo "$output" | grep -qv -- '--format'; then
    return 0
  fi
  echo "FAIL: scripts/check.sh --help output should NOT contain --format"
  return 1
}

test_test_help_has_skip_steps() {
  local output
  output=$("$REPO_ROOT/scripts/test.sh" --help 2>&1)
  if echo "$output" | grep -q -- '--skip-steps'; then
    return 0
  fi
  echo "FAIL: scripts/test.sh --help output should mention --skip-steps"
  return 1
}

test_test_help_no_skip_system_build() {
  local output
  output=$("$REPO_ROOT/scripts/test.sh" --help 2>&1)
  if echo "$output" | grep -qv -- '--skip-system-build'; then
    return 0
  fi
  echo "FAIL: scripts/test.sh --help output should NOT contain --skip-system-build"
  return 1
}

# Run all tests
echo "=== Documentation consistency tests ==="
for test in test_check_sh_has_skip_steps test_check_sh_no_format \
            test_check_ps1_has_skip_steps test_check_ps1_no_format \
            test_test_sh_has_skip_steps test_test_sh_no_skip_system_build \
            test_test_ps1_has_skip_steps test_test_ps1_no_skip_system_build \
            test_check_lib_usage_has_skip_steps test_check_lib_usage_no_format \
            test_check_lib_ps1_usage_has_skip_steps \
            test_test_lib_usage_has_skip_steps test_test_lib_usage_no_skip_system_build \
            test_test_lib_ps1_usage_has_skip_steps test_test_lib_ps1_usage_no_skip_system_build \
            test_check_help_has_skip_steps test_check_help_no_format \
            test_test_help_has_skip_steps test_test_help_no_skip_system_build; do
  if $test; then
    echo "  ✓ $test"
  else
    echo "  ✗ $test"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "--- $failures documentation test(s) failed ---"
  exit 1
fi
echo "--- All documentation consistency tests passed ---"
exit 0
