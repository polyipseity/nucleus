# shellcheck shell=bash
# shellcheck source=../check-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../check-lib.sh"

register_step "host-os-naming" 26 "Host and OS naming validation" run_26_host_os_naming

run_26_host_os_naming() {
  local _has_args="$1" _repo_root="$2"; shift 2
  cd "$_repo_root" || return 1
  local _errors=0

  # services.json must not use legacy platforms key on service entries
  if jq -e '
    to_entries[]
    | select(.key | startswith("$") | not)
    | select(.value | type == "object")
    | select(.value | has("platforms"))
  ' src/modules/services.json >/dev/null 2>&1; then
    error "services.json: legacy 'platforms' key found — use 'hosts' with platform ref"
    _errors=$((_errors + 1))
  fi

  # host-platform-registry hosts must not contain flags
  if jq -e '
    .hosts
    | to_entries[]
    | select(.value | has("flags"))
  ' src/modules/host-platform-registry.json >/dev/null 2>&1; then
    error "host-platform-registry.json: flags must live on platforms, not hosts"
    _errors=$((_errors + 1))
  fi

  # flake attrs must use canonical host names
  if ! grep -q 'darwinConfigurations\.MacBook' src/flake.nix; then
    error "flake.nix: darwinConfigurations.MacBook not found"
    _errors=$((_errors + 1))
  fi
  if ! grep -q 'nixosConfigurations\.NixOS' src/flake.nix; then
    error "flake.nix: nixosConfigurations.NixOS not found"
    _errors=$((_errors + 1))
  fi

  # env-catalog must not use macOS as a values key
  if grep -q 'values\.macOS' src/modules/lib/env-catalog.nix; then
    error "env-catalog.nix: values.macOS found — use values.MacBook"
    _errors=$((_errors + 1))
  fi

  if [ "$_errors" -gt 0 ]; then
    error "host/OS naming validation failed with $_errors error(s)"
    return 1
  fi
  say "host/OS naming validation passed"
  return 0
}
