# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "yaml-structural" 15 "YAML structural validation" run_15_yaml_structural

run_15_yaml_structural() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _yaml_errors=0
  local _yaml_par_tmpdir
  _yaml_par_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _yaml_errors=$((_yaml_errors + 1)); }

  # Collect YAML files for validation
  local _yaml_files=()
  if $_has_args; then
    for _yf in "${_files[@]}"; do
      case "$_yf" in
        *.yml|*.yaml) _yaml_files+=("$_yf") ;;
      esac
    done
  else
    for _yf in "${CACHED_YAML_FILES[@]}"; do
      _yaml_files+=("$_yf")
    done
  fi

  if [ "${#_yaml_files[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_yaml_files[@]}" \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _f="$1"
        _exit=0
        _err=$(yq eval "." "$_f" 2>&1 >/dev/null) || _exit=$?
        if [ "$_exit" -ne 0 ]; then
          printf "invalid_yaml:%s\n" "$_f"
        elif [ -n "$_err" ]; then
          printf "yaml_warn:%s:%s\n" "$_f" "$_err"
        fi
      ' _ 2>/dev/null > "$_yaml_par_tmpdir/yaml_results.txt"

    if [ -s "$_yaml_par_tmpdir/yaml_results.txt" ]; then
      local _tag _yf _warn
      while IFS=: read -r _tag _yf _warn; do
        case "$_tag" in
          invalid_yaml) _yaml_errors=$((_yaml_errors + 1)); error "invalid_yaml:$_yf" ;;
          yaml_warn) error "yaml_warn:$_yf:$_warn" ;;
        esac
      done < "$_yaml_par_tmpdir/yaml_results.txt"
    fi
  else
    say "==== 15: YAML structural validation ==== SKIPPED (no YAML files to check) ✗"
    rm -rf -- "$_yaml_par_tmpdir"
    return 0
  fi
  rm -rf -- "$_yaml_par_tmpdir"

  if [ "$_yaml_errors" -gt 0 ]; then
    error "YAML structural validation failed with $_yaml_errors error(s)"
    return 1
  fi
  say "YAML structural validation passed."
  return 0
}
