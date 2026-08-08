# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "package-manager-enforcement" 12 "Package manager usage enforcement" run_12_package_manager_enforcement

run_12_package_manager_enforcement() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

  # Skip when scoped to files outside this step's scope (no .sh/.ps1/.nix files).
  if $_has_args; then
    local _f _has_shell_files=0
    for _f in "${_files[@]}"; do
      case "$_f" in *.sh|*.ps1|*.nix) _has_shell_files=1; break ;; esac
    done
    if [ "$_has_shell_files" -eq 0 ]; then
      say "==== 12: Package manager usage enforcement ==== SKIPPED (no shell files to check)"
      return 2
    fi
  fi

  # Ban bare `pip install` and `npm install`.
  # ref: allow-and-deny-lists.instructions.md#A1 -- orchestrator/config files contain pip/npm patterns in comments; self-refs are dynamic
  local _self_sh="12-package-manager-enforcement.sh"
  local _self_ps1="12-package-manager-enforcement.ps1"
  # Convert from grep -rn --include (directory traversal without gitignore) to
  # find | filter_gitignored | xargs grep so gitignored files are excluded.
  # Keep explicit --exclude for files that legitimately contain the pattern
  # (check.sh, check.ps1, shell.nix, self-refs). Removed patterns that are now
  # covered by gitignore (e.g., result, secrets/, .direnv/).
  if find scripts/ src/ tests/ \( -name '*.sh' -o -name '*.ps1' -o -name '*.nix' \) -print \
    | filter_gitignored \
    | grep -v -E '(check\.sh|check\.ps1|shell\.nix|'"$_self_sh"'|'"$_self_ps1"')$' \
    | xargs grep -n -E '(^|[^a-z])pip install([^-]|$)' 2>/dev/null \
    | grep -v 'uv pip install' \
    | grep . >/dev/null 2>&1; then
    error "bare pip install detected (use uv pip install instead)"
    _violations=$((_violations + 1))
  fi

  if find scripts/ src/ tests/ \( -name '*.sh' -o -name '*.ps1' -o -name '*.nix' \) -print \
    | filter_gitignored \
    | grep -v -E '(check\.sh|check\.ps1|shell\.nix|'"$_self_sh"'|'"$_self_ps1"')$' \
    | xargs grep -n -E '(^|[^a-z])npm install([^-]|$)' 2>/dev/null \
    | grep . >/dev/null 2>&1; then
    error "bare npm install detected (use bun or nix instead)"
    _violations=$((_violations + 1))
  fi

  # Self-pruning: verify excluded files still justify their exclusion (A1)
  for _excluded in check.sh check.ps1 shell.nix; do
    if [ -f "$_excluded" ] && ! grep -q -E '(pip install|npm install)' "$_excluded" 2>/dev/null; then
      error "stale exclusion: '$_excluded' no longer contains pip/npm install patterns — remove from --exclude list"
      _violations=$((_violations + 1))
    fi
  done

  if [ "$_violations" -gt 0 ]; then
    return 1
  fi
  say "no package manager violations found."
  return 0
}
