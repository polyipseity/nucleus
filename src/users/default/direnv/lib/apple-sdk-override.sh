#!/usr/bin/env bash
# apple-sdk _nix() override: filter DEVELOPER_DIR, SDKROOT, and
# NIX_APPLE_SDK_VERSION out of nix print-dev-env before nix-direnv caches them.
#
# WHY lib/ and not direnvrc: direnv auto-sources lib/*.sh before direnvrc and
# before .envrc, and nix-direnv defines _nix in lib/hm-nix-direnv.sh, so this
# override lands before .envrc calls use_flake.
# https://direnv.net/man/direnv-stdlib.1.html
#
# WHY POSIX-only: the three variables are set by nix-support/setup-hook during
# macOS nix builds. The grep is a no-op on Linux and Windows, and the file is
# deployed on every POSIX host, so no platform conditional is needed.
_nix() {
  local _has_pe=0
  for _arg in "$@"; do
    if [[ "$_arg" == "print-dev-env" ]]; then
      _has_pe=1
      break
    fi
  done
  if [[ $_has_pe -eq 1 ]]; then
    # shellcheck disable=SC2154 # reason: _nix_direnv_nix is set at runtime by nix-direnv's _nix_direnv_preflight() in ~/.config/direnv/lib/hm-nix-direnv.sh — user-specific path unreachable by # shellcheck source=
    "${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@" |
      command grep -v -E '^(DEVELOPER_DIR=|SDKROOT=|NIX_APPLE_SDK_VERSION=)|^export (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$|^unset (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$' # ref: allow-and-deny-lists.instructions.md#C3 -- Nix env debug output suppression
  else
    # shellcheck disable=SC2154 # reason: _nix_direnv_nix is set at runtime by nix-direnv's _nix_direnv_preflight() in ~/.config/direnv/lib/hm-nix-direnv.sh — user-specific path unreachable by # shellcheck source=
    "${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
  fi
}
