#!/usr/bin/env bash
# Daily system Nix store GC: intersection generation prune + collect-garbage.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"
# shellcheck source=../lib/expire-profile-generations.sh
. "$SCRIPT_DIR/../lib/expire-profile-generations.sh"

_system_expiry="${NUCLEUS_GC_EXPIRY:-7d}"
_nix_expiry="${NUCLEUS_GC_NIX_EXPIRY:-${_system_expiry}}"
_generations_keep="${NUCLEUS_GC_GENERATIONS_KEEP:-7}"
_system_generations_keep="${NUCLEUS_GC_SYSTEM_GENERATIONS_KEEP:-${_generations_keep}}"

if _nsg_profile="$(resolve_system_profile)"; then
  NUCLEUS_GC_PROFILE_SUDO=false \
    expire_profile_generations_intersection \
    "$_nsg_profile" \
    "$_system_generations_keep" \
    "$_system_expiry" \
    false
else
  say "no system profile found; skipping system generation expiry"
fi

nix-collect-garbage --delete-older-than "$_nix_expiry"
