#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSIONS_FILE="$SCRIPT_DIR/bootstrap-versions.env"

COMMAND="${1:-apply}"

if [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ] || [ "$COMMAND" = "help" ]; then
  cat <<'EOF'
Usage: bootstrap.sh [command]

Commands:
  apply         Apply the full configuration for this host (default)
  install-deps  Install Nix-managed bootstrap dependencies only
  -h, --help    Show this help message
EOF
  exit 0
fi

load_bootstrap_versions() {
  if [ ! -f "$VERSIONS_FILE" ]; then
    printf '%s\n' "error: expected bootstrap versions file at $VERSIONS_FILE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  set -a
  . "$VERSIONS_FILE"
  set +a

  if [ -z "${NUCLEUS_NIX_INSTALLER_SHA256:-}" ]; then
    printf '%s\n' "error: NUCLEUS_NIX_INSTALLER_SHA256 missing in $VERSIONS_FILE" >&2
    exit 1
  fi

  if [ -z "${NUCLEUS_NIX_INSTALLER_URL:-}" ]; then
    printf '%s\n' "error: NUCLEUS_NIX_INSTALLER_URL missing in $VERSIONS_FILE" >&2
    exit 1
  fi

  NIX_INSTALLER_SHA256="$NUCLEUS_NIX_INSTALLER_SHA256"
  NIX_INSTALLER_URL="$NUCLEUS_NIX_INSTALLER_URL"
}

install_bootstrap_deps_only() {
  printf '%s\n' "Installing bootstrap-managed dependencies only..."
  nix --extra-experimental-features "nix-command flakes" profile install "$REPO_ROOT/src#bootstrap-deps"
  printf '%s\n' "Bootstrap dependencies installed. Skipping OS configuration."
}

apply_configuration() {
  os_name="$1"

  case "$os_name" in
    Darwin)
      printf '%s\n' "Applying nix-darwin configuration: macbook"
      nix --extra-experimental-features "nix-command flakes" run "$REPO_ROOT/src#darwin-rebuild" -- switch --flake "$REPO_ROOT/src#macbook"
      ;;
    Linux)
      if [ -f /etc/NIXOS ]; then
        printf '%s\n' "Applying NixOS configuration: nixos"
        sudo nix --extra-experimental-features "nix-command flakes" run "$REPO_ROOT/src#nixos-rebuild" -- switch --flake "$REPO_ROOT/src#nixos"
      else
        target_username="${NUCLEUS_USERNAME:-$(id -un)}"
        printf '%s\n' "Applying Home Manager profile: $target_username"
        nix --extra-experimental-features "nix-command flakes" run "$REPO_ROOT/src#home-manager" -- switch --flake "$REPO_ROOT/src#$target_username"
      fi
      ;;
    *)
      printf '%s\n' "error: unsupported OS '$os_name'" >&2
      exit 1
      ;;
  esac
}

bootstrap_nix_if_missing() {
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  require_command curl

  installer_path="$(mktemp)"
  curl -fsSL "$NIX_INSTALLER_URL" -o "$installer_path"

  if [ "$NIX_INSTALLER_SHA256" = "REPLACE_WITH_NIX_INSTALLER_SHA256" ]; then
    printf '%s\n' "warning: NUCLEUS_NIX_INSTALLER_SHA256 is not set; skipping installer checksum verification."
  else
    actual_sha256="$(sha256_of_file "$installer_path")"
    if [ "$actual_sha256" != "$NIX_INSTALLER_SHA256" ]; then
      printf '%s\n' "error: Nix installer checksum mismatch." >&2
      printf '%s\n' "expected: $NIX_INSTALLER_SHA256" >&2
      printf '%s\n' "actual:   $actual_sha256" >&2
      exit 1
    fi
  fi

  sh "$installer_path" --yes --no-daemon
  rm -f "$installer_path"

  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    # shellcheck disable=SC1091
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  fi

  require_command nix
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: $1 is required but was not found in PATH" >&2
    exit 1
  fi
}

run_with_bootstrap_tools() {
  nix --extra-experimental-features "nix-command flakes" develop "$REPO_ROOT/src#bootstrap" --command "$@"
}

sha256_of_file() {
  file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{ print $1 }'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{ print $1 }'
    return
  fi

  require_command openssl
  openssl dgst -sha256 "$file_path" | awk '{ print $2 }'
}

verify_secrets_access() {
  secrets_dir="$REPO_ROOT/src/secrets"
  host_ssh_key="/etc/ssh/ssh_host_ed25519_key"
  found=0

  if [ ! -d "$secrets_dir" ]; then
    printf '%s\n' "No secrets directory found at $secrets_dir; skipping decryption preflight."
    return 0
  fi

  if [ -f "$host_ssh_key" ]; then
    export SOPS_AGE_SSH_PRIVATE_KEY_FILE="$host_ssh_key"
  else
    if ! run_with_bootstrap_tools gpg --list-secret-keys --with-colons 2>/dev/null | grep -Eq '^(sec|ssb):'; then
      printf '%s\n' "error: no GPG secret keys found; import your encryption subkey first." >&2
      return 1
    fi
  fi

  for secrets_file in "$secrets_dir"/*.yml; do
    [ -e "$secrets_file" ] || continue
    found=1
    printf '%s\n' "Verifying: $(basename "$secrets_file")"
    if ! run_with_bootstrap_tools sops --decrypt --output-format json "$secrets_file" >/dev/null 2>&1; then
      unset SOPS_AGE_SSH_PRIVATE_KEY_FILE
      printf '%s\n' "error: unable to decrypt $(basename "$secrets_file") with host SSH key or GPG." >&2
      return 1
    fi
  done

  unset SOPS_AGE_SSH_PRIVATE_KEY_FILE

  if [ "$found" -eq 0 ]; then
    printf '%s\n' "No .yml secret files found in $secrets_dir; skipping."
    return 0
  fi

  printf '%s\n' "Verified secrets access."
}

load_bootstrap_versions
bootstrap_nix_if_missing

case "$COMMAND" in
  apply)
    verify_secrets_access
    OS_NAME=$(uname -s)
    apply_configuration "$OS_NAME"
    ;;
  install-deps)
    install_bootstrap_deps_only
    ;;
  *)
    printf '%s\n' "error: unsupported command '$COMMAND' (supported: apply, help, install-deps)" >&2
    exit 1
    ;;
esac
