#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "script-and-framework-tests" "Script and framework tests" run_script_and_framework_tests

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
  local _capture _status=0 _reason=""
  _capture=$(mktemp) || {
    error "failed to create capture file"
    return 1
  }

  # Captured rather than streamed, so the tally can be checked and so a failing
  # suite is not run a second time just to show the output quiet mode suppressed.
  if [ "$(basename "$_script")" = "nucleus-apps-smoke-tests.sh" ]; then
    nucleus_nix_locked bash "$_script" >"$_capture" 2>&1 || _status=$?
  else
    bash "$_script" >"$_capture" 2>&1 || _status=$?
  fi

  if [ "$quiet_mode" != true ] || [ "$_status" -ne 0 ]; then
    cat "$_capture"
  fi

  if ! _reason=$(check_suite_tally "$_script" "$_capture" "$_status"); then
    error "FAILED script tests: $(basename "$_script") — $_reason"
    _status=1
  fi

  rm -f "$_capture"
  return "$_status"
}

_run_parallel_script_tests() {
  local _repo_root="$1"
  shift
  local -a _scripts=("$@")
  local _capture_dir _failed_list _script _capture_file _status _reason _exit_code=0

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

  # shellcheck disable=SC2016 # reason: $1-$4 are sh -c positional params, not shell expansion
  printf '%s\0' "${_scripts[@]}" | xargs -0 -P "$PARALLEL_JOBS" -I{} sh -c '
    script="$1"
    capture_dir="$2"
    repo_root="$3"
    quiet_mode="$4"
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
    _rc=0
    run_one >"$capture_file" 2>&1 || _rc=$?
    printf '%s' "$_rc" >"$capture_dir/$base.rc"
  ' _ {} "$_capture_dir" "$_repo_root" "$quiet_mode"

  for _script in "${_scripts[@]}"; do
    _capture_file="$_capture_dir/$(basename "$_script").out"
    _status=0
    _reason=""
    if [ -f "$_capture_dir/$(basename "$_script").rc" ]; then
      _status=$(cat "$_capture_dir/$(basename "$_script").rc")
    fi
    # Judged here rather than inside the xargs job: this runs in the step's own
    # shell, where the tally checker is defined, and it leaves the parallel job
    # one job — run the suite and record its status.
    if ! _reason=$(check_suite_tally "$_script" "$_capture_file" "$_status"); then
      printf '%s (%s)\n' "$_script" "$_reason" >>"$_failed_list"
    elif [ "$_status" -ne 0 ]; then
      printf '%s\n' "$_script" >>"$_failed_list"
    fi
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

run_script_and_framework_tests() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
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
