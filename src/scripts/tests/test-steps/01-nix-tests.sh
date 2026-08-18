#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "nix-tests" "Nix test suite" run_nix_tests

run_nix_tests() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _exit_code=0
  local _tmp_failed

  _tmp_failed=$(mktemp) || {
    error "failed to create temp file"
    return 1
  }

  # shellcheck source=../../lib/nix-test-eval.sh
  . "$_repo_root/src/scripts/lib/nix-test-eval.sh"
  if ! run_nix_test_eval false "$_repo_root"; then
    _exit_code=1
  fi

  if [ "$_exit_code" -eq 0 ]; then
    bash "$_repo_root/tests/scripts/check-steps/nix-test-eval-tests.sh" || _exit_code=1
  fi

  if [ "$_exit_code" -ne 0 ]; then
    rm -f "$_tmp_failed"
    return "$_exit_code"
  fi

  # WHY: nix-instantiate evals contend on the shared SQLite eval cache and
  # ~/.cache/nix/flake-registry.json when test steps 1/4/5 run concurrently;
  # hold the nix lock for the whole eval phase so cross-step nix invocations
  # serialize. Evals run serially (xargs -P 1) because parallel imports of
  # <nixpkgs> race on flake-registry updates.
  nucleus_nix_locked _run_eval_phase "$_tmp_failed"

  if [ -s "$_tmp_failed" ]; then
    error "FAILED Nix tests:"
    cat "$_tmp_failed" >&2
    _exit_code=1
  fi
  rm -f "$_tmp_failed"

  if [ "$_exit_code" -eq 0 ]; then
    say "all Nix tests passed."
  fi
  return "$_exit_code"
}

# Runs the serial nix-instantiate phase under the nix lock (see
# nucleus_nix_locked in step-runner.sh). Failures are recorded in the temp
# file passed as $1; the lock wrapper's exit status is not a test verdict.
_run_eval_phase() {
  local _tmp_failed="$1"

  if [ "$quiet_mode" = true ]; then
    # shellcheck disable=SC2016 # reason: $1/$2 are sh -c positional params, not shell expansion
    printf '%s\0' "${TEST_NIX_FILES_ARR[@]}" | xargs -0 -P 1 -I{} sh -c '
          f="$1"; tmp="$2"
          if out=$(nix-instantiate --eval --strict "$f" 2>&1); then
            true
          else
            echo "FAIL: $f" >&2
            echo "$f" >> "$tmp"
            echo "$out" >&2
          fi
        ' _ {} "$_tmp_failed"
  else
    # shellcheck disable=SC2016 # reason: $1/$2 are sh -c positional params, not shell expansion
    printf '%s\0' "${TEST_NIX_FILES_ARR[@]}" | xargs -0 -P 1 -I{} sh -c '
          f="$1"
          echo "Testing: $f" >&2
          if ! nix-instantiate --eval --strict "$f"; then
            echo "FAIL: $f" >&2
            echo "$f" >> "$2"
          else
            echo "PASS: $f" >&2
          fi
        ' _ {} "$_tmp_failed"
  fi
}
