#!/usr/bin/env sh
# Apply the nucleus configuration for this host.
# Run via:  nix run ./src#apply
# Or:       sh src/scripts/apply.sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
NIX_EXTRA_FEATURES="nix-command flakes"

apply_configuration() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "Applying nix-darwin configuration: macbook"
      nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
        run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        printf '%s\n' "Applying NixOS configuration: nixos"
        sudo nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
          run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      else
        target_username="${NUCLEUS_USERNAME:-$(id -un)}"
        printf '%s\n' "Applying Home Manager profile: $target_username"
        nix --extra-experimental-features "$NIX_EXTRA_FEATURES" \
          run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      fi
      ;;
    *)
      printf '%s\n' "error: unsupported OS '$(uname -s)'" >&2
      exit 1
      ;;
  esac
}

apply_configuration
