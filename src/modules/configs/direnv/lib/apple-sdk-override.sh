#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apple-sdk _nix() override: filter DEVELOPER_DIR, SDKROOT, NIX_APPLE_SDK_VERSION
# from nix print-dev-env output before nix-direnv caches them.
# ---------------------------------------------------------------------------
#
# Why lib/ (not direnvrc):
#   direnv auto-sources ~/.config/direnv/lib/*.sh before ~/.config/direnv/direnvrc
#   and before the .envrc.  Since nix-direnv defines _nix in lib/hm-nix-direnv.sh,
#   this override (sourced before direnvrc) takes effect before .envrc calls use_flake.
#   See: https://direnv.net/man/direnv-stdlib.1.html
#
# Why POSIX-only (not Windows):
#   DEVELOPER_DIR, SDKROOT, and NIX_APPLE_SDK_VERSION are apple-sdk environment
#   variables set by nix-support/setup-hook during macOS nix builds.  They don't
#   exist on Linux (NixOS) or Windows — the grep is a no-op there, but the file
#   is deployed on all POSIX hosts via the shared shell.nix module.  No conditional
#   needed; the runtime behavior is correct on all platforms.
#
# See also: app-config-policy.instructions.md (Host-specific lib/ subdirectory convention)
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
    "${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@" \
      | command grep -v -E '^(DEVELOPER_DIR=|SDKROOT=|NIX_APPLE_SDK_VERSION=)|^export (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$|^unset (DEVELOPER_DIR|SDKROOT|NIX_APPLE_SDK_VERSION)$'  # ref: EXCLUDE-LISTS.md#C3 — reason: Nix env debug output suppression
  else
    # shellcheck disable=SC2154 # reason: _nix_direnv_nix is set at runtime by nix-direnv's _nix_direnv_preflight() in ~/.config/direnv/lib/hm-nix-direnv.sh — user-specific path unreachable by # shellcheck source=
    "${_nix_direnv_nix}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
  fi
}
