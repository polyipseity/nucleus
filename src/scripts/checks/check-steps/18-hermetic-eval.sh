# shellcheck shell=bash
# shellcheck source=../check-lib.sh
# (provides say, error, warn, register_step, skip_step)
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "hermetic-eval" "Hermetic Nix eval (no env vars, no --impure)" run_hermetic_eval

# run_hermetic_eval — Prove the Nix layer evaluates without any forwarded environment
# variable and without --impure. Phase 3-6 threaded repoRoot/keyCatalogPath via
# specialArgs and dropped every builtins.getEnv read, so the flake must now evaluate
# cleanly with NUCLEUS_REPO_ROOT / NUCLEUS_CATALOG_PATH unset.
#
# Darwin must build hermetically (exit 0). NixOS currently carries a PRE-EXISTING,
# out-of-scope config conflict (programs.ssh.startAgent vs services.gnome.gcr-ssh-agent.enable
# in src/hosts/NixOS/{security,desktop}.nix) that blocks any NixOS build regardless of
# impurity. We therefore assert NixOS hermetic eval reaches the assertion stage — i.e. it
# gets past all module-arg resolution (impurity gone) and fails only on that known conflict,
# not on a getEnv / required-argument error. An impurity regression surfaces as a
# "called without required argument 'repoRoot'/'keyCatalogPath'" failure, which this step
# treats as a hard error.
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
  if ! nucleus_nix_locked env -u NUCLEUS_REPO_ROOT -u NUCLEUS_CATALOG_PATH \
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
  if nucleus_nix_locked env -u NUCLEUS_REPO_ROOT -u NUCLEUS_CATALOG_PATH \
    NIX_CONFIG="$_nix_cfg" \
    nix build "./src#nixosConfigurations.NixOS.config.system.build.toplevel" --dry-run \
    >"$_nixos_out" 2>&1; then
    say "nixos hermetic eval passed (no env vars, no --impure)."
  else
    # Impurity regression: a missing specialArgs value surfaces as a required-argument
    # error at module-arg resolution, BEFORE assertions. That must hard-fail.
    if grep -Eq "required argument 'repoRoot'|required argument 'keyCatalogPath'|getEnv" "$_nixos_out"; then
      error "nixos hermetic eval regressed to env-var dependency:"
      cat "$_nixos_out" >&2
      _exit=1
    elif grep -q "gcr-ssh-agent" "$_nixos_out"; then
      # Pre-existing, out-of-scope config conflict (ssh.startAgent vs gcr-ssh-agent).
      # Reaching it proves module-arg resolution (impurity) is gone.
      skip_step "$(step_number)" "Hermetic Nix eval" \
        "nixos hermetic eval reached assertion stage; pre-existing ssh.startAgent vs gcr-ssh-agent conflict (out of scope)"
      _exit=2
    else
      error "nixos hermetic eval failed for an unexpected reason:"
      cat "$_nixos_out" >&2
      _exit=1
    fi
  fi
  rm -f "$_nixos_out"

  return $_exit
}
