#!/usr/bin/env sh
# src/scripts/apply.sh — Dispatch the Nix apply command for the current host.
#
# Detects the operating system and invokes the appropriate flake output:
#   Darwin  → darwin-rebuild switch  (nix-darwin; manages system + home-manager)
#   NixOS   → nixos-rebuild switch   (requires sudo; detected via /etc/NIXOS)
#   Linux   → home-manager switch    (standalone HM for plain Linux / WSL)
#
# Environment variables:
#   NUCLEUS_USERNAME — override the Home Manager profile name used on standalone
#                      Linux.  Defaults to `id -un` (the current user).  Set
#                      this when the local username differs from the key used
#                      in homeConfigurations in flake.nix.
#
# Prerequisites: Nix installed; caller's environment must allow reaching the
# nix binary.  nix-command and flakes features are passed explicitly so the
# script works even when they are not pre-enabled in nix.conf.
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
# Pass experimental features at every nix invocation rather than relying on
# nix.conf so the script is portable to freshly bootstrapped machines where
# the system config has not yet been applied.
NIX_EXTRA_FEATURES="nix-command flakes"
case "$(uname -s)" in
  Darwin)
    # nix-darwin manages both the system layer and the user Home Manager profile.
    nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
    ;;
  Linux)
    if [ -f /etc/NIXOS ]; then
      # NixOS: use nixos-rebuild so the system layer and the embedded
      # home-manager module are applied in a single atomic activation.
      sudo nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
    else
      # Standalone Home Manager (plain Linux or WSL): no NixOS system layer.
      # The profile name must match the homeConfigurations key in flake.nix.
      target_username="${NUCLEUS_USERNAME:-$(id -un)}"
      nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac
