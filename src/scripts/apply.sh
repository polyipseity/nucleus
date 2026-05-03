#!/usr/bin/env sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
NIX_EXTRA_FEATURES="nix-command flakes"
case "$(uname -s)" in
  Darwin) nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook" ;;
  Linux) if [ -f /etc/NIXOS ]; then sudo nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"; else target_username="${NUCLEUS_USERNAME:-$(id -un)}"; nix --extra-experimental-features "$NIX_EXTRA_FEATURES" run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"; fi ;;
  *) printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2; exit 1 ;;
esac
