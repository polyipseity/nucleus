# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step 4 "Nix flake evaluation" run_04_nix_flake_eval

run_04_nix_flake_eval() {
  local _step="$1" _has_args="$2" _repo_root="$3" _wave_tmpdir="$4"; shift 4
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _ne_exit=0
  local _nix_eval_nix_files=()

  if $_has_args; then
    _nix_eval_nix_files=("${NIX_FILES[@]+${NIX_FILES[@]}}")
  else
    if command -v git >/dev/null 2>&1; then
      while IFS= read -r _f; do
        _nix_eval_nix_files+=("$_f")
      done < <({ git diff --name-only HEAD -- '*.nix' 2>/dev/null || true; git ls-files --others --exclude-standard '*.nix' 2>/dev/null || true; } | sort -u || true)
    fi
  fi

  if [ "${#_nix_eval_nix_files[@]}" -gt 0 ]; then
    local sys
    sys=$(nix eval --impure --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
    if ! nix eval --impure "path:./src#packages.$sys" >/dev/null; then
      _ne_exit=1
    else
      say "nix flake evaluation passed."
    fi
  else
    say "skipping (no Nix files changed since HEAD)."
  fi

  return $_ne_exit
}
