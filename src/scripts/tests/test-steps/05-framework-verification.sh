#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "framework-verification" 5 "Framework verification" run_05_framework_verification

run_05_framework_verification() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0
  local _test_dir="$_repo_root/tests/scripts"

  say "--- framework unit tests ---"
  bash "$_test_dir/step-runner-unit-tests.sh" || _exit_code=1
  bash "$_test_dir/test-lib-unit-tests.sh" || _exit_code=1
  bash "$_test_dir/deny-list-tests.sh" || _exit_code=1
  bash "$_test_dir/android-config-tests.sh" || _exit_code=1

  say "--- step-specific tests ---"
  bash "$_test_dir/check-steps/09-schema-validation-tests.sh" || _exit_code=1
  bash "$_test_dir/load-user-registry-tests.sh" || _exit_code=1

  return "$_exit_code"
}
