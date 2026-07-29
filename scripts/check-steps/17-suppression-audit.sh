# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 17 "Undocumented error suppression" run_17_suppression_audit

run_17_suppression_audit() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _s17_errors=0
  local _step17_tmpdir
  _step17_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _s17_errors=$((_s17_errors + 1)); }

  # Collect script files
  local _step17_files=()
  if $_has_args; then
    [ ${#SH_FILES[@]} -gt 0 ] && _step17_files+=("${SH_FILES[@]}")
    [ ${#NIX_FILES[@]} -gt 0 ] && _step17_files+=("${NIX_FILES[@]}")
  else
    _step17_files=("${CACHED_NIX_FILES[@]}" "${CACHED_SH_FILES[@]}")
  fi

  if [ "${#_step17_files[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_step17_files[@]}" \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _safe="$(echo "$1" | tr "/" "_")"
        _out="$2/${_safe}.out"
        _content=$(<"$1")
        _line_no=0
        while IFS= read -r _line; do
          _line_no=$((_line_no + 1))
          case "$_line" in
            *shellcheck\ disable=*|*check-suppress:*)
              if ! echo "$_line" | grep -q "reason:"; then
                echo "undoc_supp:${1}:${_line_no}:${_line}" >> "$_out"
              fi
              ;;
          esac
        done <<< "$_content"
      ' _ "$_step17_tmpdir"

    local _f _err
    for _f in "$_step17_tmpdir"/*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _s17_errors=$((_s17_errors + 1))
        error "$_err"
      done < "$_f"
    done

    if [ "$_s17_errors" -gt 0 ]; then
      say "  add '# check-suppress:suppression_doc: reason' comment to explain intentional suppressions."
      rm -rf -- "$_step17_tmpdir"
      return 1
    else
      say "no undocumented error suppressions found."
    fi
  else
    say "no undocumented error suppressions found."
  fi

  rm -rf -- "$_step17_tmpdir"
  return 0
}
