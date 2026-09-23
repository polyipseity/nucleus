# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, require_command, derive_repo_root, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "nix-flake-eval" "Nix flake evaluation" run_nix_flake_eval

run_nix_flake_eval() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
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

    # Hermetic eval: prove Nix layer evaluates without forwarded env vars.
    run_hermetic_eval "$1" || _ne_exit=1
  else
    say "0 Nix files in scope — nothing to evaluate."
  fi

  return $_ne_exit
}

# run_hermetic_eval — Prove the Nix layer evaluates without any forwarded environment
# variable and without --impure. The env catalog is a static Nix attrset in the
# repo tree, so the flake must now evaluate cleanly with NUCLEUS_REPO_ROOT unset.
run_hermetic_eval() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _exit=0

  local -n _nix_files="${ctx[NIX_FILES]}"
  if $_has_args && [ "${#_nix_files[@]}" -eq 0 ]; then
    say "0 Nix files in scope — nothing to evaluate hermetically."
    return 0
  fi

  cd "$_repo_root" || return 1
  local _nix_cfg
  _nix_cfg="$(merge_nix_config)"

  # --- Darwin: must build hermetically (exit 0) ---
  if ! nucleus_nix_locked env -u NUCLEUS_REPO_ROOT \
    NIX_CONFIG="$_nix_cfg" \
    nix build "./src#darwinConfigurations.MacBook.config.system.build.toplevel" --dry-run >/dev/null; then
    error "darwin hermetic eval failed (expected exit 0 with no env vars and no --impure)"
    _exit=1
  else
    say "darwin hermetic eval passed (no env vars, no --impure)."
  fi

  # --- NixOS: hermetic eval must reach the assertion stage, not fail on impurity ---
  local _nixos_out
  _nixos_out="$(mktemp)"
  if nucleus_nix_locked env -u NUCLEUS_REPO_ROOT \
    NIX_CONFIG="$_nix_cfg" \
    nix build "./src#nixosConfigurations.NixOS.config.system.build.toplevel" --dry-run \
    >"$_nixos_out" 2>&1; then
    say "nixos hermetic eval passed (no env vars, no --impure)."
  else
    if grep -Eq "required argument 'repoRoot'|getEnv" "$_nixos_out"; then
      error "nixos hermetic eval regressed to env-var dependency:"
      cat "$_nixos_out" >&2
      _exit=1
    else
      error "nixos hermetic eval failed for an unexpected reason:"
      cat "$_nixos_out" >&2
      _exit=1
    fi
  fi
  rm -f "$_nixos_out"

  return $_exit
}
