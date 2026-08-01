# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "legacy-token-syntax" 23 "Legacy token syntax gate" run_23_legacy_token_syntax

run_23_legacy_token_syntax() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1

  local _s23_errors=0
  # Exclude this check's own file: its source contains the literal detection pattern.
  # ref: allow-and-deny-lists.instructions.md#C6 — reason: self-refs are dynamic
  local _s23_self_sh
  _s23_self_sh="$(basename "${BASH_SOURCE[0]}")"

  # Token convention scope: production code under src/ and scripts/ with code
  # extensions — same scope as the Pester gate
  # (tests/hosts/Windows/embedded-content/no-legacy-token-syntax.Tests.ps1).
  # .md prose and tests/ fixtures are excluded by scope (they cite the legacy form).
  local _scan_files=()
  if $_has_args; then
    for _f in "${_files[@]}"; do
      case "$_f" in
        src/*|scripts/*)
          case "$_f" in
            *.ps1|*.sh|*.zsh|*.nix|*.yml) [ "$(basename "$_f")" = "$_s23_self_sh" ] || _scan_files+=("$_f") ;;
          esac
          ;;
      esac
    done
  else
    while IFS= read -r -d '' _f; do
      case "$_f" in
        *.ps1|*.sh|*.zsh|*.nix|*.yml) _scan_files+=("$_f") ;;
      esac
    done < <(find src scripts -type f \( -name '*.ps1' -o -name '*.sh' -o -name '*.zsh' -o -name '*.nix' -o -name '*.yml' \) -not -name "$_s23_self_sh" -print0)
    mapfile -t _scan_files < <(printf '%s\n' "${_scan_files[@]}" | filter_gitignored)
  fi

  if [ "${#_scan_files[@]}" -gt 0 ]; then
    local _s23_violation
    while IFS= read -r _s23_violation; do
      _s23_errors=$((_s23_errors + 1))
      error "$_s23_violation"
    done < <(grep -nH -E '\{\{[A-Za-z_]' "${_scan_files[@]}")
  fi

  if [ "$_s23_errors" -gt 0 ]; then
    say "  Use double-underscore UPPER_SNAKE placeholders — see .agents/instructions/embedded-content.instructions.md section 4."
    return 1
  fi

  say "no legacy token placeholder syntax found."
  return 0
}
