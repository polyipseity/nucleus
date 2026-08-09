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
    nix-test-eval-tests | check-pwsh-tests) continue ;;
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

_is_priority_script_test() {
  case "$(basename "$1")" in
  step-runner-unit-tests.sh | test-lib-unit-tests.sh | deny-list-tests.sh) return 0 ;;
  *) return 1 ;;
  esac
}

_run_script_test() {
  local _script="$1"

  if [ "$(basename "$_script")" = "nucleus-apps-smoke-tests.sh" ]; then
    if [ "$quiet_mode" = true ]; then
      if ! nucleus_nix_locked bash "$_script" >/dev/null; then
        nucleus_nix_locked bash "$_script"
        return 1
      fi
      return 0
    fi
    nucleus_nix_locked bash "$_script"
    return $?
  fi

  if [ "$quiet_mode" = true ]; then
    if ! bash "$_script" >/dev/null; then
      bash "$_script"
      return 1
    fi
    return 0
  fi

  bash "$_script"
}

_run_parallel_script_tests() {
  local _repo_root="$1"
  shift
  local -a _scripts=("$@")
  local _capture_dir _failed_list _script _exit_code=0

  if [ "${#_scripts[@]}" -eq 0 ]; then
    return 0
  fi

  _capture_dir=$(mktemp -d) || {
    error "failed to create capture dir"
    return 1
  }
  _failed_list=$(mktemp) || {
    error "failed to create failed list"
    rm -rf "$_capture_dir"
    return 1
  }

  for _script in "${_scripts[@]}"; do
    say "running $(basename "$_script")"
  done

  # shellcheck disable=SC2016 # reason: $1/$2/$3 are sh -c positional params, not shell expansion
  printf '%s\0' "${_scripts[@]}" | xargs -0 -P "$PARALLEL_JOBS" -I{} sh -c '
    script="$1"
    capture_dir="$2"
    failed_list="$3"
    repo_root="$4"
    quiet_mode="$5"
    base=$(basename "$script")
    capture_file="$capture_dir/$base.out"
    run_one() {
      if [ "$base" = "nucleus-apps-smoke-tests.sh" ]; then
        . "$repo_root/src/scripts/lib/step-runner.sh"
        if [ "$quiet_mode" = true ]; then
          nucleus_nix_locked bash "$script"
        else
          nucleus_nix_locked bash "$script"
        fi
      elif [ "$quiet_mode" = true ]; then
        bash "$script"
      else
        bash "$script"
      fi
    }
    if ! run_one >"$capture_file" 2>&1; then
      printf "%s\n" "$script" >> "$failed_list"
    fi
  ' _ {} "$_capture_dir" "$_failed_list" "$_repo_root" "$quiet_mode"

  for _script in "${_scripts[@]}"; do
    _capture_file="$_capture_dir/$(basename "$_script").out"
    if [ -f "$_capture_file" ]; then
      cat "$_capture_file"
    fi
  done

  if [ -s "$_failed_list" ]; then
    error "FAILED script tests:"
    cat "$_failed_list" >&2
    _exit_code=1
  fi

  rm -rf "$_capture_dir"
  rm -f "$_failed_list"
  return "$_exit_code"
}

run_05_script_and_framework_tests() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _exit_code=0
  local _test_dir="$_repo_root/tests/scripts"
  local -a _all_scripts=() _priority_scripts=() _parallel_scripts=()
  local _test_script

  while IFS= read -r -d '' _test_script; do
    [ -n "$_test_script" ] || continue
    _all_scripts+=("$_test_script")
  done < <(_discover_script_tests "$_test_dir")

  for _test_script in "${_all_scripts[@]}"; do
    if _is_priority_script_test "$_test_script"; then
      _priority_scripts+=("$_test_script")
    else
      _parallel_scripts+=("$_test_script")
    fi
  done

  say "--- discovered script tests ---"

  for _test_script in "${_priority_scripts[@]}"; do
    say "running $(basename "$_test_script")"
    if ! _run_script_test "$_test_script"; then
      _exit_code=1
    fi
  done

  if ! _run_parallel_script_tests "$_repo_root" "${_parallel_scripts[@]}"; then
    _exit_code=1
  fi

  return "$_exit_code"
}
