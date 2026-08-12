# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "nix-lint" "Nix lint (nixf-tidy)" run_nix_lint

run_nix_lint() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _nixf_files=()
  local _nixf_exit=0

  if [ "${#NIX_FILES[@]}" -gt 0 ]; then
    _nixf_files=("${NIX_FILES[@]}")
  elif ! $_has_args; then
    _nixf_files=("${CACHED_NIX_FILES[@]}")
  else
    _nixf_files=()
  fi

  if [ "${#_nixf_files[@]}" -gt 0 ]; then
    local _nixf_tmpdir
    _nixf_tmpdir=$(mktemp -d) || {
      error "failed to create temp directory"
      return 1
    }
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_nixf_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        tmpdir="$1"
        f="$2"
        safe_name="$(echo "$f" | tr "/" "_")"
        if ! out=$(nixf-tidy < "$f" 2>&1); then
          printf "FAIL\n%s\n" "$f" > "$tmpdir/${safe_name}.nixf"
        elif [ "$(echo "$out" | jq "length" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
          printf "ISSUES\n%s\n%s\n" "$f" "$out" > "$tmpdir/${safe_name}.nixf"
        fi
      ' _ "$_nixf_tmpdir"

    local _nixf_result _nixf_status _nixf_file_path
    for _nixf_result in "$_nixf_tmpdir"/*.nixf; do
      [ -f "$_nixf_result" ] || continue
      IFS= read -r _nixf_status <"$_nixf_result"
      IFS= read -r _nixf_file_path <"$_nixf_result"
      case "$_nixf_status" in
      FAIL)
        error "$_nixf_file_path: nixf-tidy failed"
        _nixf_exit=$((_nixf_exit + 1))
        ;;
      ISSUES)
        tail -n +3 "$_nixf_result" | jq -r '.[] | "\(.sname): \(.message)"' | while IFS= read -r _nixf_issue; do
          error "$_nixf_file_path: $_nixf_issue"
        done
        _nixf_exit=$((_nixf_exit + 1))
        ;;
      esac
    done
    [ -n "$_nixf_tmpdir" ] && rm -rf -- "$_nixf_tmpdir"
  else
    say "==== $(step_number): Nix lint (nixf-tidy) ==== SKIPPED (no Nix files to check)"
    return 2
  fi

  if [ "$_nixf_exit" -gt 0 ]; then
    return 1
  else
    say "nixf-tidy lint passed."
    return 0
  fi
}
