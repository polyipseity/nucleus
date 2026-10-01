#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "system-config-build" "System config build" run_system_config_build any any sops-machine-key

# _sops_secrets_available <host> <repo-root>
# 0 when every secret in src/hosts/<host>/sops.nix is decryptable from its
# sopsFile with the machine age key, 1 otherwise.
_sops_secrets_available() {
  local _host="$1" _repo_root="$2"
  local _sops_nix="$_repo_root/src/hosts/$_host/sops.nix"
  [ -f "$_sops_nix" ] || return 0 # no host sops overrides → nothing to verify

  local _sops_dir
  _sops_dir="$(CDPATH='' cd -- "$(dirname -- "$_sops_nix")" && pwd)"

  # sopsFile paths are relative to the sops.nix directory.
  local _name="" _file="" _rel="" _abs="" _ok=0 _missing=()
  while IFS= read -r _line; do
    if [[ "$_line" == *sops.secrets.* ]] && [[ "$_line" == *\"* ]]; then
      # Extract the quoted secret name: sops.secrets."<name>" = { ...
      _name="${_line#*sops.secrets.}"
      _name="${_name#\"}"
      _name="${_name%%\"*}"
      _file=""
    elif [[ "$_line" == *sopsFile* ]]; then
      _file="${_line##*sopsFile = }"
      _file="${_file%;}"
      _file="${_file#\"}"
      _file="${_file%\"}"
      if [ -n "$_name" ] && [ -n "$_file" ]; then
        _rel="$(CDPATH='' cd -- "$_sops_dir" && pwd)/$_file"
        _abs="$(CDPATH='' cd -- "$(dirname -- "$_rel")" && pwd)/$(basename -- "$_rel")"
        if [ ! -f "$_abs" ]; then
          _missing+=("$_name (sopsFile $_file missing)")
        elif ! SOPS_AGE_KEY_FILE="$(nucleus_machine_age_key_path)" sops --decrypt "$_abs" 2>/dev/null |
          grep -qE "^$_name:"; then
          _missing+=("$_name (not present in $_file)")
        fi
        _name=""
      fi
    fi
  done <"$_sops_nix"

  if [ "${#_missing[@]}" -gt 0 ]; then
    echo "sops secret material unavailable: ${_missing[*]}" >&2
    return 1
  fi
  return 0
}

run_system_config_build() {
  local -n ctx="$1"
  local _has_args="${ctx[HAS_ARGS]}" _repo_root="${ctx[REPO_ROOT]}"
  shift
  local _exit_code=0

  local _host=""
  _host="$(resolve_nucleus_host)"
  export NUCLEUS_REPO_ROOT="$_repo_root"

  # The runner gates this step on sops-machine-key, so the key exists here. A
  # secret wired into sops.nix but absent from the encrypted material is a repo
  # inconsistency the build cannot recover from, so fail with the diagnostic.
  if ! _sops_secrets_available "$_host" "$_repo_root"; then
    error "sops secret material unavailable for host $_host"
    return 1
  fi

  case "$_host" in
  MacBook) _attr="darwinConfigurations.MacBook.system" ;;
  NixOS)
    if [ -d /etc/nixos ]; then
      _attr="nixosConfigurations.NixOS.config.system.build.toplevel"
    else
      _primary="$(NUCLEUS_REPO_ROOT="$_repo_root" "$_repo_root/src/scripts/lib/load-user-registry.sh" \
        --host NixOS --repo-root "$_repo_root" | jq -r '.primaryUser')"
      _attr="homeConfigurations.${_primary}.activationPackage"
    fi
    ;;
  *)
    error "unsupported host '$_host' in system config build"
    return 1
    ;;
  esac

  # WHY: this build contends on the SQLite eval cache and the flakehub fetch lock
  # with the other nix steps, so it is serialized. min-free = 0 disables Nix
  # auto-GC so a full Data volume cannot delete flake-input trees mid-eval.
  _nix_cfg="$(merge_nix_config)"
  if [ "$quiet_mode" = true ]; then
    NIX_CONFIG="$_nix_cfg" nucleus_nix_locked nix build --no-link --keep-going --print-out-paths "./src#$_attr" >/dev/null || _exit_code=$?
  else
    NIX_CONFIG="$_nix_cfg" nucleus_nix_locked nix build --no-link --keep-going --print-out-paths "./src#$_attr" || _exit_code=$?
  fi

  return "$_exit_code"
}
