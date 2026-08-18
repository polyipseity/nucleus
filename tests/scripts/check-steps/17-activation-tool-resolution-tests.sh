#!/usr/bin/env bash
# shellcheck shell=bash
# Test: step 17 activation-tool-resolution enforces resolved tool paths

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/src/scripts/checks/check-steps/17-activation-tool-resolution.sh"

test_step17_awk_program_present() {
  if grep -q 'AWKEOF' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should contain an inline awk program"
  return 1
}

test_step17_self_exclusion() {
  if grep -q '_self_sh' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should exclude itself from candidate files"
  return 1
}

test_step17_activation_dirs() {
  # Must scan activation-script directories.
  local _count=0
  for _dir in src/scripts/packages src/scripts/shell src/scripts/agents src/scripts/secrets src/scripts/services src/scripts/vms src/scripts/configs src/scripts/editors src/scripts/integrations src/scripts/completions; do
    if grep -q "$_dir" "$TEST_FILE"; then
      _count=$((_count + 1))
    fi
  done
  if [ "$_count" -ge 5 ]; then
    return 0
  fi
  echo "FAIL: step 17 should list activation-script directories (found $_count)"
  return 1
}

test_step17_lib_function_loading() {
  if grep -q 'LIB_FUNCS_FILE' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should dynamically load lib function names"
  return 1
}

test_step17_command_name_validation() {
  # Must validate command names with a regex that rejects flags, globs, etc.
  if grep -q '\^\[a-z_\]' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should validate command names with a regex"
  return 1
}

test_step17_heredoc_detection() {
  if grep -q 'heredoc' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should track heredoc state"
  return 1
}

test_step17_case_tracking() {
  if grep -q 'case_depth' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should track case/esac blocks"
  return 1
}

test_step17_path_prepend_tracking() {
  if grep -q 'path_provided' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should track PATH= prepends"
  return 1
}

test_step17_error_format() {
  if grep -q 'bare external command' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should report violations with 'bare external command' message"
  return 1
}

test_step17_shellcheck_directive() {
  if grep -q 'shellcheck shell=bash' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should have a shellcheck directive"
  return 1
}

test_step17_register_step() {
  if grep -q 'register_step.*activation-tool-resolution' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should register as 'activation-tool-resolution'"
  return 1
}

test_step17_allowlist_builtins() {
  # Should have a builtins allowlist in the awk program.
  if grep -q 'Shell builtins' "$TEST_FILE" || grep -q 'Coreutils' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should define allowlists for builtins/coreutils"
  return 1
}

test_step17_min_length_filter() {
  # Should skip short tokens (length < 3) to avoid false positives.
  if grep -q 'length(cmd)' "$TEST_FILE"; then
    return 0
  fi
  echo "FAIL: step 17 should filter short command tokens"
  return 1
}

# --- Run all tests ---
_failures=0
for test_func in $(declare -F | grep -o 'test_step17_\w\+'); do
  if ! "$test_func"; then
    _failures=$((_failures + 1))
  fi
done

if [ "$_failures" -gt 0 ]; then
  echo "FAILED: $_failures test(s) failed"
  exit 1
fi
echo "All step 17 shell tests passed."
