# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"
# shellcheck source=../../lib/key-catalog.sh
# (provides ensure_key_catalog so the key-catalog.generated.nix artifact exists
# for pure Nix eval)
. "$_NUCLEUS_LIB_DIR/key-catalog.sh"

register_step "nix-flake-eval" "Nix flake evaluation" run_nix_flake_eval

run_nix_flake_eval() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  # Generate the key-catalog.generated.nix artifact so pure Nix eval can import
  # the catalog.
  ensure_key_catalog
  local _ne_exit=0
  local _ne_eval=false

  local -n _nix_files="${ctx[NIX_FILES]}"
  if $_has_args; then
    # Scoped mode: evaluate only when the scoped files include .nix changes.
    if [ "${#_nix_files[@]}" -gt 0 ]; then
      _ne_eval=true
    fi
  else
    # Full mode: always evaluate the flake regardless of git diff — a clean
    # tree must still be checked (issue 8; the diff gate used to skip
    # evaluation entirely when nothing changed since HEAD).
    _ne_eval=true
  fi

  if $_ne_eval; then
    # WHY: both evals write the shared SQLite eval cache; serialize them with
    # the test steps' nix invocations (pre-push check and test may overlap).
    local sys
    sys=$(nucleus_nix_locked nix eval --expr 'builtins.currentSystem' --raw 2>/dev/null || echo 'aarch64-darwin')
    if ! nucleus_nix_locked nix eval "path:./src#packages.$sys" >/dev/null; then
      _ne_exit=1
    else
      say "nix flake evaluation passed."
    fi
  else
    say "skipping (no Nix files in scope)."
    return 2
  fi

  return $_ne_exit
}
