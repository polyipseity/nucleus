# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 16 "Package manager usage enforcement" run_16_package_manager_enforcement

run_16_package_manager_enforcement() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _violations=0

  # Ban bare `pip install` and `npm install`.
  # ref: allow-and-deny-lists.instructions.md#A1 — reason: orchestrator/config files contain pip/npm patterns in comments; self-refs are dynamic
  local _self_sh _self_ps1
  _self_sh="$(basename "${BASH_SOURCE[0]}")"
  _self_ps1="$(basename "${BASH_SOURCE[0]}" .sh).ps1"
  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
       --exclude="$_self_sh" \
       --exclude="$_self_ps1" \
       -E '(^|[^a-z])pip install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
       | grep -v 'uv pip install' \
       | grep . >/dev/null 2>&1; then
    error "bare pip install detected (use uv pip install instead)"
    _violations=$((_violations + 1))
  fi

  if grep -rn --include='*.sh' --include='*.ps1' --include='*.nix' \
       --exclude='check.sh' --exclude='check.ps1' --exclude='shell.nix' \
       --exclude="$_self_sh" \
       --exclude="$_self_ps1" \
       -E '(^|[^a-z])npm install([^-]|$)' \
       scripts/ src/ tests/ 2>/dev/null \
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
