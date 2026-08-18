# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "store-path-arg-usage" "Store-path arg variable usage enforcement" run_store_path_arg_usage

run_store_path_arg_usage() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

  # This step only applies to shell scripts.
  if $_has_args; then
    local _f _has_sh_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh)
        _has_sh_files=1
        break
        ;;
      esac
    done
    if [ "$_has_sh_files" -eq 0 ]; then
      skip_step "$(step_number)" "Store-path arg variable usage enforcement" "no shell files to check"
      return 2
    fi
  fi

  # Collect candidate files: all .sh files under scripts/ and src/scripts/ (not
  # test fixtures, not check steps themselves).
  # ref: comment-annotations.instructions.md#C1 -- self-derived basenames for exclusion
  # shellcheck disable=SC2155 # reason: basename's exit status is irrelevant; self-derived for exclusion
  local _self_sh="$(basename "${BASH_SOURCE[0]}")"
  local _self_ps1="${_self_sh%.sh}.ps1"
  local _candidate_files=()

  # Files excluded from this check: their _X_bin variables are used as config
  # parameters (not commands), so the check would produce false positives.
  local _exclude_pattern='(check\.sh|'"$_self_sh"'|'"$_self_ps1"'|configure-gpg-agent\.sh)$'

  if $_has_args; then
    local _f
    for _f in "${_files[@]}"; do
      case "$_f" in
      *.sh) _candidate_files+=("$_f") ;;
      esac
    done
    local _filtered=()
    for _f in "${_candidate_files[@]}"; do
      case "$(basename "$_f")" in
      check.sh | "$_self_sh" | "$_self_ps1") continue ;;
      esac
      _filtered+=("$_f")
    done
    _candidate_files=("${_filtered[@]}")
  else
    mapfile -t _candidate_files < <(
      find scripts/ src/scripts/ -name '*.sh' -print |
        filter_gitignored |
        grep -v -E "$_exclude_pattern"
    )
  fi

  if [ "${#_candidate_files[@]}" -eq 0 ]; then
    skip_step "$(step_number)" "Store-path arg variable usage enforcement" "no shell files to check"
    return 2
  fi

  # Also collect ALL .sh files for cross-file usage search (variables may be
  # exported and consumed in other scripts, e.g., _ds_gawk_bin).
  local _all_sh_files=()
  mapfile -t _all_sh_files < <(
    find scripts/ src/scripts/ -name '*.sh' -print |
      filter_gitignored
  )

  # Phase 1: extract _X_bin="$N" declarations from candidate files.
  # Format: "file:line:varname" where N is a positional arg $1-$9 or ${10}+.
  local _decls=()
  local _file
  for _file in "${_candidate_files[@]}"; do
    local _line
    while IFS= read -r _line; do
      _decls+=("$_line")
    done < <(grep -HnE '_[a-z][a-z0-9_]*_bin="\$[0-9]+"' "$_file" 2>/dev/null)
  done

  if [ "${#_decls[@]}" -eq 0 ]; then
    say "no store-path arg declarations found."
    return 0
  fi

  # Phase 2: for each declared variable, verify it has at least one command/PATH
  # usage across all shell scripts. A usage counts as "command-like" if the
  # variable reference appears outside a condition test or declaration.
  #
  # Detection strategy: grep for "$_var" or "${_var" references across all
  # shell scripts, then exclude lines that are declarations or condition checks.
  # If zero non-excluded references remain → the variable is unused as a command.
  local _decl _var _file _line_num
  for _decl in "${_decls[@]}"; do
    # Parse "file:line:varname=..."
    _file="${_decl%%:*}"
    _line_num="${_decl#*:}"
    _line_num="${_line_num%%:*}"
    _var="${_decl##*:}"
    _var="${_var%%=*}"
    # Trim leading/trailing whitespace from variable name.
    _var="${_var#"${_var%%[![:space:]]*}"}"
    _var="${_var%"${_var##*[![:space:]]}"}"

    # Search all shell scripts for "$_var" and "${_var" references.
    # These patterns catch: "$var", "${var}", "${var:-default}", "${var%/*}".
    local _all_refs=0 _non_condition_refs=0
    local _search_file
    for _search_file in "${_all_sh_files[@]}"; do
      local _refs
      # check-suppress:suppression_doc: grep returns exit 1 on no match; || true allows empty result
      _refs=$(grep -n "\"\\\${${_var}\|\"\\\$${_var}" "$_search_file" 2>/dev/null \
        || true) # check-suppress:suppression_doc: grep returns exit 1 on no match; || true allows empty result
      [ -z "$_refs" ] && continue

      _all_refs=$((_all_refs + $(echo "$_refs" | wc -l)))

      # Exclude: declarations (var="$N"), condition checks ([ -z/-n "$var" ]).
      local _filtered
      _filtered=$(echo "$_refs" | \
        grep -v -E "^[0-9]+:[[:space:]]*_?[a-z_]*=\"\\\$[0-9]+\"" | \
        grep -v -E "^[0-9]+:[[:space:]]*\[\[?\s+-[zn]\s" \
        || true) # check-suppress:suppression_doc: grep returns exit 1 when all lines are filtered; || true allows empty result
      # check-suppress:suppression_doc: grep -c returns exit 1 on zero matches; || true counts as 0
      _non_condition_refs=$((_non_condition_refs + $(echo "$_filtered" | grep -c . || true)))
    done

    if [ "$_all_refs" -eq 0 ]; then
      # Variable is declared but never referenced at all.
      error "store-path arg variable ${_var} in ${_file} is declared but never referenced"
      _violations=$((_violations + 1))
    elif [ "$_non_condition_refs" -eq 0 ]; then
      # Variable is only referenced in condition checks — never as a command.
      error "store-path arg variable ${_var} in ${_file} is only used in condition checks, never as a command or PATH entry"
      _violations=$((_violations + 1))
    fi
  done

  if [ "$_violations" -eq 0 ]; then
    say "all store-path arg variables have command/PATH usage."
    return 0
  fi
  return 1
}
