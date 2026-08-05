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
  bash "$_test_dir/check-step-file-structure-tests.sh" || _exit_code=1
  bash "$_test_dir/deny-list-tests.sh" || _exit_code=1
  bash "$_test_dir/vm-template-render-tests.sh" || _exit_code=1
  bash "$_test_dir/gui-env-tests.sh" || _exit_code=1

  say "--- step-specific tests ---"
  bash "$_test_dir/check-steps/01-code-formatting-tests.sh" || _exit_code=1
  bash "$_test_dir/check-steps/05-nix-lint-explicit-skip.sh" || _exit_code=1
  bash "$_test_dir/check-steps/11-lockfile-validation-explicit-skip.sh" || _exit_code=1
  bash "$_test_dir/check-steps/13-schema-validation-tests.sh" || _exit_code=1
  bash "$_test_dir/check-steps/15-yaml-structural-explicit-skip.sh" || _exit_code=1
  bash "$_test_dir/check-steps/16-package-manager-enforcement-explicit-skip.sh" || _exit_code=1
  bash "$_test_dir/check-steps/17-suppression-audit-explicit-skip.sh" || _exit_code=1
  bash "$_test_dir/check-steps/22-embedded-content-enforcement-tests.sh" || _exit_code=1
  bash "$_test_dir/check-steps/23-legacy-token-syntax-tests.sh" || _exit_code=1
  bash "$_test_dir/check-steps/24-nix-test-eval-tests.sh" || _exit_code=1
  bash "$_test_dir/check-steps/25-vm-manifest-regression-tests.sh" || _exit_code=1

  say "--- integration smoke tests ---"
  bash "$_test_dir/integration-smoke-tests.sh" || _exit_code=1

  say "--- documentation consistency tests ---"
  bash "$_test_dir/documentation-consistency-tests.sh" || _exit_code=1

  return "$_exit_code"
}
