#!/usr/bin/env sh
# Apply the nucleus configuration for this host.
# Run via:  nix run ./src#apply          (gpg/git/jq/sops provided automatically)
# Or:       sh src/scripts/apply.sh     (requires git, gpg, jq, nix, sops in PATH)
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
HOST_SSH_KEY="/etc/ssh/ssh_host_ed25519_key"
NIX_EXTRA_FEATURES="nix-command flakes"
SECRETS_DIR="$REPO_ROOT/src/secrets"

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

verify_secrets_access() {
  found=0

  if [ ! -d "$SECRETS_DIR" ]; then
    printf '%s\n' "No secrets directory found at $SECRETS_DIR; skipping preflight."
    return 0
  fi

  if [ -f "$HOST_SSH_KEY" ]; then
    export SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOST_SSH_KEY"
  else
    if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -Eq '^(sec|ssb):'; then
      printf '%s\n' "error: no GPG secret keys found; import your encryption subkey first." >&2
      return 1
    fi
  fi

  for secrets_file in "$SECRETS_DIR"/*.yml; do
    [ -e "$secrets_file" ] || continue
    found=1
    printf '%s\n' "Verifying: $(basename "$secrets_file")"
    if ! sops --decrypt --output-format json "$secrets_file" >/dev/null 2>&1; then
      unset SOPS_AGE_SSH_PRIVATE_KEY_FILE
      printf '%s\n' "error: cannot decrypt $(basename "$secrets_file")." >&2
      return 1
    fi
  done

  unset SOPS_AGE_SSH_PRIVATE_KEY_FILE

  if [ "$found" -eq 0 ]; then
    printf '%s\n' "No .yml secret files found in $SECRETS_DIR; skipping preflight."
  else
    printf '%s\n' "All secrets accessible."
  fi
}

verify_secrets_access
apply_configuration
