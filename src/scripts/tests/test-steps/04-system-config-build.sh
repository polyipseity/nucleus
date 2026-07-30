#!/usr/bin/env bash
# shellcheck source=../test-lib.sh
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../test-lib.sh"

register_step 4 "System config build" run_04_system_config_build

run_04_system_config_build() {
  local _has_args="$1" _repo_root="$2"; shift 2
  local _exit_code=0

  if [ "$skip_system_build" = true ]; then
    say "skipping (--skip-system-build)."
    return 0
  fi

  local _attr=""
  case "$(uname)" in
    Darwin) _attr="darwinConfigurations.macbook.system" ;;
    Linux)
      if [ -d /etc/nixos ]; then
        _attr="nixosConfigurations.nixos.config.system.build.toplevel"
      else
        _attr="homeConfigurations.polyipseity.activationPackage"
      fi
      ;;
    *)
      say "system config build: unsupported OS ($(uname)), skipping."
      return 0
      ;;
  esac

  if [ "$quiet_mode" = true ]; then
    nix build --no-link --keep-going --print-out-paths "./src#$_attr" >/dev/null || _exit_code=$?
  else
    nix build --no-link --keep-going --print-out-paths "./src#$_attr" || _exit_code=$?
  fi

  return "$_exit_code"
}
