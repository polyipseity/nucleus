# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "nix-flake-eval" "Nix flake evaluation and managed config keys" run_nix_flake_eval posix any none

run_nix_flake_eval() {
  local -n ctx="$1"
  local _ctx_name="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _ne_exit=0
  local _ne_eval=false

  local -n _nix_files="${ctx[NIX_FILES]}"
  if $_has_args; then
    # Scoped mode evaluates only when the scoped files include .nix changes.
    if [ "${#_nix_files[@]}" -gt 0 ]; then
      _ne_eval=true
    fi
  else
    # Full mode always evaluates: a clean tree must still be checked.
    _ne_eval=true
  fi

  if $_ne_eval; then
    # Each remaining nix invocation keeps its own call because three lanes are
    # in play and a merge would drop the contract of the lane that gave up its
    # environment or its real output. Real build: the pin exports NIX_PATH for
    # the whole step, and the winget check needs the store path it prints for
    # cmp. Env-present eval: `nix config show system` and the package eval must
    # read the environment this host's nix runs with. Env-clean hermetic: the
    # dry-run below strips NUCLEUS_REPO_ROOT and forces its own NIX_CONFIG.
    # WHY: <nixpkgs> comes from the flake-locked input, never from this
    # machine's channel; the evals below must not depend on the ambient one.
    if ! nucleus_pin_nixpkgs "$_repo_root"; then
      _ne_exit=1
    fi

    # WHY: these nix calls write the shared SQLite eval cache; serialize them
    # with the test steps' nix invocations (pre-push check and test may overlap).
    # WHY: builtins.currentSystem is unavailable under pure eval, so a probe
    # that suppressed stderr and fell back to a hardcoded aarch64-darwin
    # reported the darwin system on every host and made the eval below target
    # the wrong package set on Linux. `nix config show system` is pure, cheap,
    # and follows a configured `system = ...` exactly as `nix build` would.
    local sys
    sys="$(nucleus_nix_locked nix config show system)"
    if ! nucleus_nix_locked nix eval "path:./src#packages.$sys" >/dev/null; then
      _ne_exit=1
    else
      say "nix flake evaluation passed."
    fi

    # Committed generated artifacts must equal their flake derivation.
    # WHY: src/hosts/Windows/system/winget-packages.json cannot be generated on
    # Windows, so it is committed, and this is the only byte-exact (format
    # inclusive) check of it; the always-run nix-tests step compares the parsed
    # entry set and pins the root-key order on every POSIX host instead.
    # WHY: ./src#winget-packages builds the macOS package set, so it is an
    # aarch64-darwin derivation no other host can build. Check it only where the
    # host system matches, and say it was not checked elsewhere.
    # It stays its own real build: cmp compares the store path this command
    # prints, and a dry-run prints no path.
    local _ne_ga_out
    if [ "$sys" != "aarch64-darwin" ]; then
      say "winget allow-list freshness not checked: ./src#winget-packages is an aarch64-darwin derivation (host system: $sys)."
    elif _ne_ga_out="$(nucleus_nix_locked nix build --no-link --print-out-paths ./src#winget-packages)"; then
      if ! cmp -s "$_ne_ga_out" src/hosts/Windows/system/winget-packages.json; then
        error "src/hosts/Windows/system/winget-packages.json is stale — regenerate it from its derivation (see .agents/instructions/winget-dsc.instructions.md)"
        _ne_exit=1
      else
        say "generated winget allow-list matches its derivation."
      fi
    else
      error "failed to build ./src#winget-packages for the generated-artifact check"
      _ne_exit=1
    fi

    # Hermetic eval: prove Nix layer evaluates without forwarded env vars.
    # The env-clean lane is one dry-run over both system targets: nix build
    # takes the whole installable list in a single run (help synopsis
    # `nix build [option...] installables...`, description "nix build builds the
    # specified installables"), so the targets share one process instead of two.
    run_hermetic_eval "$_ctx_name" || _ne_exit=1

    # Nix lint (nixf-tidy)
    run_nixf_tidy "$_ctx_name" || _ne_exit=1
  else
    say "0 Nix files in scope — nothing to evaluate."
  fi

  # WHY: the keys are validated in every mode, because this reads a config file
  # rather than the flake and a scoped run must not be able to skip it (the same
  # always-run rule step 05 follows). The file is consumed only where it is
  # deployed, so its keys are judged by the nix that reads it, not by whatever nix
  # happens to run here.
  if managed_nix_conf_check_applies; then
    run_nix_conf_key_check "$_ctx_name" || _ne_exit=1
  fi

  return $_ne_exit
}

# managed_nix_conf_check_applies: the managed nix.conf is consumed only where it is
# deployed, so a host whose nix never reads it must not judge its keys.
managed_nix_conf_check_applies() {
  if [ -e /etc/nix/nix.custom.conf ]; then
    return 0
  fi
  say "/etc/nix/nix.custom.conf is not deployed on this host: managed nix config keys not checked."
  return 1
}

# run_nix_conf_key_check: every setting the managed nix.conf declares must be a
# setting this nix reads. Nix only warns about an unknown name in a config file,
# so a key that is not a setting never applies and nothing else reports it.
run_nix_conf_key_check() {
  local -n ctx="$1"
  local _nc_repo_root="${ctx[REPO_ROOT]}"
  shift
  local _nc_rel="src/modules/configs/nix/nix.custom.conf"
  local _nc_file="$_nc_repo_root/$_nc_rel"
  local _nc_key_count=0
  local _nc_line _nc_trim _nc_key _nc_err

  # WHY: a missing managed config is a defect in the tree, never a reason to
  # pass quietly; the file is the only statement of the daemon's settings.
  if [ ! -f "$_nc_file" ]; then
    error "$_nc_rel: managed nix config not found"
    return 1
  fi

  while IFS= read -r _nc_line || [ -n "$_nc_line" ]; do
    # Strip leading whitespace, then ignore comments (prose and commented-out
    # settings alike) and anything that is not a setting-name line.
    _nc_trim="${_nc_line#"${_nc_line%%[![:space:]]*}"}"
    case "$_nc_trim" in
    '' | '#'*) continue ;;
    *=*) ;;
    *) continue ;;
    esac
    _nc_key="${_nc_trim%%=*}"
    _nc_key="${_nc_key%"${_nc_key##*[![:space:]]}"}"
    case "$_nc_key" in
    '' | *[!A-Za-z0-9_-]*) continue ;;
    esac
    _nc_key_count=$((_nc_key_count + 1))
  done <"$_nc_file"

  # WHY: one parse of the whole file, so nix judges exactly what the daemon
  # reads: the setting names, the `extra-` append aliases it resolves itself, and
  # the values. An unknown name warns on stderr and still exits 0, so stderr is
  # the only signal for it; a bad value or a syntax error exits non-zero.
  # WHY: no nix lock here. The lock serializes the flake evals' shared SQLite eval
  # cache, and a config parse touches none of it, so taking it only adds a way
  # to block behind an unrelated nix process. It joins no other invocation
  # either: it parses the managed file as NIX_CONFIG, a config contract no
  # other nix call in this step shares.
  if ! _nc_err="$(NIX_CONFIG="$(cat "$_nc_file")" nix config show max-jobs 2>&1 >/dev/null)"; then
    error "$_nc_rel: nix rejected the managed config: $_nc_err"
    return 1
  fi
  case "$_nc_err" in
  *"unknown setting"*)
    while IFS= read -r _nc_line; do
      case "$_nc_line" in
      *"unknown setting"*) error "$_nc_rel: $_nc_line" ;;
      esac
    done <<<"$_nc_err"
    return 1
    ;;
  esac

  say "managed nix config keys passed ($_nc_key_count keys)."
  return 0
}

# run_hermetic_eval: prove the Nix layer evaluates with no forwarded
# environment variable and no --impure. The env catalog is a static attrset in
# the repo tree, so the flake must evaluate with NUCLEUS_REPO_ROOT unset.
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

  # One env-clean dry-run carries both system targets, so exit 0 is the
  # contract for each of them: the darwin target must build hermetically, and
  # the nixos target must reach a clean evaluation rather than an impurity
  # failure. When the single call is non-zero, the captured output is what
  # still separates the failure modes: the repoRoot/getEnv pattern is the
  # env-dependency signature, and any other text is an unexpected failure.
  local _hermetic_out
  _hermetic_out="$(mktemp)"
  if nucleus_nix_locked env -u NUCLEUS_REPO_ROOT \
    NIX_CONFIG="$_nix_cfg" \
    nix build --dry-run \
    "./src#darwinConfigurations.MacBook.config.system.build.toplevel" \
    "./src#nixosConfigurations.NixOS.config.system.build.toplevel" \
    >"$_hermetic_out" 2>&1; then
    say "darwin and nixos hermetic evals passed (no env vars, no --impure)."
  else
    if grep -Eq "required argument 'repoRoot'|getEnv" "$_hermetic_out"; then
      error "hermetic eval regressed to env-var dependency (darwin or nixos):"
    else
      error "hermetic eval failed for an unexpected reason (expected exit 0 with no env vars and no --impure):"
    fi
    cat "$_hermetic_out" >&2
    _exit=1
  fi
  rm -f "$_hermetic_out"

  return $_exit
}

# run_nixf_tidy: lint Nix files.
run_nixf_tidy() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _files=("$@")
  cd "$_repo_root" || return 1
  local _nixf_files=()
  local _nixf_exit=0

  local -n _nix_files="${ctx[NIX_FILES]}"
  local -n _cached_nix_files="${ctx[CACHED_NIX_FILES]}"
  if [ "${#_nix_files[@]}" -gt 0 ]; then
    _nixf_files=("${_nix_files[@]}")
  elif ! $_has_args; then
    _nixf_files=("${_cached_nix_files[@]}")
  else
    _nixf_files=()
  fi

  if [ "${#_nixf_files[@]}" -gt 0 ]; then
    local _nixf_tmpdir
    _nixf_tmpdir=$(mktemp -d) || {
      error "failed to create temp directory"
      return 1
    }
    # shellcheck disable=SC2016 # reason: child-shell parameter expansion in bash -c
    printf '%s\0' "${_nixf_files[@]}" |
      xargs -0 -P "$PARALLEL_JOBS" -n 1 bash -c '
        tmpdir="$1"
        f="$2"
        safe_name="$(echo "$f" | tr "/" "_")"
        if ! out=$(nixf-tidy < "$f" 2>&1); then
          printf "FAIL\n%s\n" "$f" > "$tmpdir/${safe_name}.nixf"
        elif [ "$(echo "$out" | jq "length" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
          printf "ISSUES\n%s\n%s\n" "$f" "$out" > "$tmpdir/${safe_name}.nixf"
        fi
      ' _ "$_nixf_tmpdir"

    local _nixf_result _nixf_status _nixf_file_path
    for _nixf_result in "$_nixf_tmpdir"/*.nixf; do
      [ -f "$_nixf_result" ] || continue
      IFS= read -r _nixf_status <"$_nixf_result"
      IFS= read -r _nixf_file_path <"$_nixf_result"
      case "$_nixf_status" in
      FAIL)
        error "$_nixf_file_path: nixf-tidy failed"
        _nixf_exit=$((_nixf_exit + 1))
        ;;
      ISSUES)
        tail -n +3 "$_nixf_result" | jq -r '.[] | "\(.sname): \(.message)"' | while IFS= read -r _nixf_issue; do
          error "$_nixf_file_path: $_nixf_issue"
        done
        _nixf_exit=$((_nixf_exit + 1))
        ;;
      esac
    done
    [ -n "$_nixf_tmpdir" ] && rm -rf -- "$_nixf_tmpdir"
  else
    say "0 Nix files in scope — nothing to lint."
  fi

  if [ "$_nixf_exit" -gt 0 ]; then
    return 1
  else
    say "nixf-tidy lint passed."
    return 0
  fi
}
