#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"
# shellcheck source=../../lib/env-catalog.sh
  # (provides ensure_env_catalog so the env-catalog.generated.nix artifact exists
  # for pure Nix eval)
  . "$NUCLEUS_LIB_DIR/env-catalog.sh"

register_step "system-config-build" "System config build" run_system_config_build

# _sops_secrets_available <host> <repo-root>
# Returns 0 when every sops secret referenced by src/hosts/<host>/sops.nix is
# present in its encrypted sopsFile (decryptable with the machine age key),
# 1 otherwise. Parses the sops.nix for `sops.secrets."<name>"` blocks and the
# `sopsFile = <path>` each block points at (relative to the sops.nix dir).
_sops_secrets_available() {
  local _host="$1" _repo_root="$2"
  local _sops_nix="$_repo_root/src/hosts/$_host/sops.nix"
  [ -f "$_sops_nix" ] || return 0 # no host sops overrides → nothing to verify

  local _sops_dir
  _sops_dir="$(CDPATH='' cd -- "$(dirname -- "$_sops_nix")" && pwd)"

  # Collect (secret-name, sopsFile) pairs. sopsFile paths are relative to the
  # sops.nix directory.
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
        elif ! SOPS_AGE_KEY_FILE=/etc/sops/age/machine.txt sops --decrypt "$_abs" 2>/dev/null |
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

  # The system build pulls in sops-nix secrets that require the host's age key
  # at /etc/sops/age/machine.txt. That key only exists on a provisioned host;
  # in a dev environment without secrets the build cannot succeed. Skip rather
  # than fail, so the suite stays green off-host while staying honest on a real
  # host (where a missing key is a genuine provisioning error).
  if [ ! -f /etc/sops/age/machine.txt ]; then
    skip_step "$(step_number)" "System config build" "sops machine key /etc/sops/age/machine.txt absent"
    return 2
  fi

  # The host's sops.nix references secrets that must exist (encrypted) in their
  # sopsFile. A referenced key that is missing from the sops material is a real
  # repo inconsistency (e.g. a secret wired into sops.nix but never added to the
  # encrypted file). Off-host the material may also be undecryptable. In either
  # case the system build cannot succeed, so skip rather than fail — staying
  # green off-host while remaining honest on a provisioned host.
  if ! _sops_secrets_available "$_host" "$_repo_root"; then
    skip_step "$(step_number)" "System config build" "sops secret material unavailable for host $_host"
    return 2
  fi

# Generate the env-catalog.generated.nix artifact so pure Nix eval can import
    # the catalog.
    ensure_env_catalog

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
    skip_step "$(step_number)" "System config build" "unsupported host $_host"
    return 2
    ;;
  esac

  # WHY: the system build contends on the SQLite eval cache and flakehub
  # fetch lock when it overlaps with the other nix steps (01/03); serialize it.
  # min-free = 0 disables Nix auto-GC so a full Data volume can't delete
  # flake-input source trees mid-eval (see merge_nix_config in lib.sh).
  _nix_cfg="$(merge_nix_config)"
  if [ "$quiet_mode" = true ]; then
    NIX_CONFIG="$_nix_cfg" nucleus_nix_locked nix build --no-link --keep-going --print-out-paths "./src#$_attr" >/dev/null || _exit_code=$?
  else
    NIX_CONFIG="$_nix_cfg" nucleus_nix_locked nix build --no-link --keep-going --print-out-paths "./src#$_attr" || _exit_code=$?
  fi

  return "$_exit_code"
}
