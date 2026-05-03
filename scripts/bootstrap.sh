#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if ! command -v nix >/dev/null 2>&1; then
  printf '%s\n' "error: nix is required but was not found in PATH" >&2
  exit 1
fi

OS_NAME=$(uname -s)

case "$OS_NAME" in
  Darwin)
    printf '%s\n' "Applying nix-darwin configuration: macbook"
    nix run nix-darwin -- switch --flake "$REPO_ROOT/src#macbook"
    ;;
  Linux)
    if command -v nixos-rebuild >/dev/null 2>&1; then
      printf '%s\n' "Applying NixOS configuration: nixos"
      sudo nixos-rebuild switch --flake "$REPO_ROOT/src#nixos"
    else
      if ! command -v home-manager >/dev/null 2>&1; then
        printf '%s\n' "error: home-manager not found (required for non-NixOS Linux)" >&2
        exit 1
      fi
      printf '%s\n' "Applying Home Manager profile: user"
      home-manager switch --flake "$REPO_ROOT/src#user"
    fi
    ;;
  *)
    printf '%s\n' "error: unsupported OS '$OS_NAME'" >&2
    exit 1
    ;;
esac
