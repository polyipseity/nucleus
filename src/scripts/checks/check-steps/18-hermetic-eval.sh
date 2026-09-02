# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, register_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "hermetic-eval" "Hermetic Nix eval (no env vars, no --impure)" run_hermetic_eval

# run_hermetic_eval — Prove the Nix layer evaluates without any forwarded environment
# variable and without --impure. The env catalog is a static Nix attrset in the
# repo tree, so the flake must now evaluate cleanly with NUCLEUS_REPO_ROOT unset.
#
# Darwin and NixOS must BOTH build hermetically (exit 0). The NixOS ssh.startAgent vs
# GNOME ssh-agent conflict (src/hosts/NixOS/{security,desktop}.nix) was resolved by forcing
# the GNOME agent off in security.nix (mirrors the base-guest precedent), so NixOS no longer
# carries any out-of-scope blocker. This step therefore asserts NixOS hermetic eval reaches
# exit 0 — there is NO skip fallback. An impurity regression surfaces as a "called without
# required argument 'repoRoot'/'envCatalogPath'" failure, which this step treats as a hard
# error.
run_hermetic_eval() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _exit=0

  local -n _nix_files="${ctx[NIX_FILES]}"
  if $_has_args && [ "${#_nix_files[@]}" -eq 0 ]; then
    say "skipping (no Nix files in scope)."
    return 2
  fi

  cd "$_repo_root" || return 1
  # WHY: serialize nix invocations on the shared SQLite eval cache / flakehub lock
  # (step-runner.instructions.md). The darwin dry-run is a full system closure eval and
  # contends with the other nix steps (03); the lock keeps them from racing.
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
    # Impurity regression: a missing specialArgs value surfaces as a required-argument
    # error at module-arg resolution, BEFORE assertions. That must hard-fail.
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
