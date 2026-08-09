#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step "system-config-build" 4 "System config build" run_04_system_config_build

run_04_system_config_build() {
  local _has_args="$1" _repo_root="$2"
  shift 2
  local _exit_code=0

  local _host=""
  _host="$(resolve_nucleus_host)"
  export NUCLEUS_REPO_ROOT="$_repo_root"
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
    say "system config build: unsupported host ($_host), skipping."
    return 2
    ;;
  esac

  # WHY: the system build contends on the SQLite eval cache and flakehub
  # fetch lock when it overlaps with the other nix steps (01/03); serialize it.
  if [ "$quiet_mode" = true ]; then
    nucleus_nix_locked nix build --impure --no-link --keep-going --print-out-paths "./src#$_attr" >/dev/null || _exit_code=$?
  else
    nucleus_nix_locked nix build --impure --no-link --keep-going --print-out-paths "./src#$_attr" || _exit_code=$?
  fi

  return "$_exit_code"
}
