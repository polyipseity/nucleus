# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "preflight-install-command-policy" 21 "Preflight InstallCommand policy" run_21_preflight_install_command_policy

run_21_preflight_install_command_policy() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s21_errors=0
  # Exclude this check's own sibling file: its source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#B6 — reason: structural invariant; self-refs are dynamic
  local _s21_self_ps1
  _s21_self_ps1="$(basename "${BASH_SOURCE[0]}" .sh).ps1"

  # Collect PowerShell files
  local _ps1_files=()
  if $_has_args; then
    if [ ${#PS1_FILES[@]} -gt 0 ]; then
      # Drop this check's own sibling file from the scoped set
      for _f in "${PS1_FILES[@]}"; do
        [ "$(basename "$_f")" = "$_s21_self_ps1" ] || _ps1_files+=("$_f")
      done
    fi
  else
    # Find all .ps1 files outside vendor/ and this check's own sibling
    while IFS= read -r -d '' _f; do
      _ps1_files+=("$_f")
    done < <(find . -name '*.ps1' -not -name "$_s21_self_ps1" -not -path './vendor/*' -not -path './.git/*' -print0)
    # Apply gitignore filter as a second pass (find -print0 uses null separators,
    # which filter_gitignored doesn't support directly)
    mapfile -t _ps1_files < <(printf '%s\n' "${_ps1_files[@]}" | filter_gitignored)
  fi

  if [ "${#_ps1_files[@]}" -gt 0 ]; then
    local _s21_tmpdir
    _s21_tmpdir=$(mktemp -d) || { error "failed to create temp dir"; _s21_errors=$((_s21_errors + 1)); }

    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_ps1_files[@]}" \
      | xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        _f="$2"
        _out="$1/$(echo "$_f" | tr "/" "_").out"
        grep -Hn "Assert-ToolAvailable.*-InstallCommand" "$_f" >> "$_out" 2>/dev/null || true
      ' _ "$_s21_tmpdir"

    local _f _err
    for _f in "$_s21_tmpdir"/*.out; do
      [ -f "$_f" ] || continue
      while IFS= read -r _err; do
        _s21_errors=$((_s21_errors + 1))
        error "$_err"
      done < "$_f"
    done

    rm -rf -- "$_s21_tmpdir"

    if [ "$_s21_errors" -gt 0 ]; then
      say "  Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
      return 1
    fi
  fi

  say "no preflight InstallCommand violations found."
  return 0
}
