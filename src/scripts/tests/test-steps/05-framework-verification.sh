#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "script-and-framework-tests" 5 "Script and framework tests" run_05_script_and_framework_tests

# Discover tests/scripts/**/*-tests.sh in stable order: priority framework suites first,
# then everything else lexicographically. Excludes suites wired to other test steps.
_discover_script_tests() {
  local _test_dir="$1"
  local -a _all=() _ordered=() _seen=()
  local _f _base _priority

  while IFS= read -r -d '' _f; do
    _all+=("$_f")
  done < <(find "$_test_dir" -type f -name '*-tests.sh' -print0 | LC_ALL=C sort -z)

  for _priority in step-runner-unit-tests test-lib-unit-tests deny-list-tests; do
    for _f in "${_all[@]}"; do
      _base="$(basename "$_f")"
      if [ "$_base" = "${_priority}.sh" ]; then
        _ordered+=("$_f")
        _seen+=("$_f")
      fi
    done
  done

  for _f in "${_all[@]}"; do
    _base="$(basename "$_f" .sh)"
    case "$_base" in
      nix-test-eval-tests|check-pwsh-tests) continue ;;
    esac
    local _already=false
    for _seen_f in "${_seen[@]}"; do
      if [ "$_seen_f" = "$_f" ]; then
        _already=true
        break
      fi
    done
    if ! $_already; then
      _ordered+=("$_f")
    fi
  done

  printf '%s\0' "${_ordered[@]}"
}

run_05_script_and_framework_tests() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0
  local _test_dir="$_repo_root/tests/scripts"
  local _test_script

  say "--- discovered script tests ---"
  while IFS= read -r -d '' _test_script; do
    [ -n "$_test_script" ] || continue
    say "running $(basename "$_test_script")"
    bash "$_test_script" || _exit_code=1
  done < <(_discover_script_tests "$_test_dir")

  return "$_exit_code"
}
