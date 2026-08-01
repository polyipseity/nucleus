# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "suppression-audit" 17 "Undocumented error suppression" run_17_suppression_audit

run_17_suppression_audit() {
  local _has_args="$1" _repo_root="$2"; shift 2
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
    # xargs passes each filename as $2; $1 is the tempdir bound in bash -c above.
    # ref: check-step-xargs-bash-c-arg-convention
    printf '%s\0' "${_step17_files[@]}" \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _safe="$(echo "$2" | tr "/" "_")"
        _out="$1/${_safe}.out"
        _s17_grep_pattern="shellcheck disable=|check-suppress:"  # reason: self-reference — grep pattern literal, not a suppression
        grep -Hn -E "$_s17_grep_pattern" "$2" \
          | grep -v -E "reason:|suppression_doc:|config-method|embedded-content|packer_validate|SuppressMessageAttribute" \
          | sed "s/^/undoc_supp:/" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: grep exits 1 on no matches; an empty .out file is the clean signal
        # Bare "|| true" suppressions (mirrors the ps1 twin Get-UndocSuppViolation
        # -Pattern "|| true"): documented by "# check-suppress:suppression_doc:" on
        # the same or preceding line; test fixtures (tests/) are exempt.
        case "$2" in
          *"/tests/"* | "tests/"*) ;;
          *)
            awk "
              /^[[:space:]]*#/ { prev = \$0; next }
              /\|\| true/ {
                if (\$0 !~ /check-suppress:suppression_doc:/ && prev !~ /# check-suppress:suppression_doc:/) {
                  print FILENAME \":\" FNR \":|| true: \" \$0
                }
              }
              { prev = \$0 }
            " "$2" | sed "s/^/undoc_supp:/" >> "$_out" 2>/dev/null || true  # check-suppress:suppression_doc: awk exits 1 on no || true matches; an empty .out file is the clean signal
            ;;
        esac
      ' _ "$_step17_tmpdir"

    local _f _err
    # Full mode produces .out files with leading dots (find . yields ./-prefixed
    # paths); the plain *.out glob misses dotfiles, so match them explicitly.
    for _f in "$_step17_tmpdir"/*.out "$_step17_tmpdir"/.*.out; do
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
    say "==== 17: Suppression audit ==== SKIPPED (no script files to check)"
    rm -rf -- "$_step17_tmpdir"
    return 2
  fi

  rm -rf -- "$_step17_tmpdir"
  return 0
}
