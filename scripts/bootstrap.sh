#!/usr/bin/env sh
# Install Nix (if absent) and the Nix-managed bootstrap dependencies.
# After running this script, apply the configuration with: nix run ./src#apply
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSIONS_FILE="$SCRIPT_DIR/bootstrap-versions.env"
COMMAND="${1:-install-deps}"

if [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ] || [ "$COMMAND" = "help" ]; then
  cat <<'EOF'
Usage: bootstrap.sh [install-deps|apply]

Installs Nix (if absent) and the Nix-managed bootstrap dependencies
(gnupg, jq, sops) for this host.

Commands:
  install-deps  Install bootstrap dependencies only (default)
  apply         Install bootstrap dependencies, then run src apply flow

Options:
  -h, --help    Show this help message
EOF
  exit 0
fi

if [ "$COMMAND" != "apply" ] && [ "$COMMAND" != "install-deps" ]; then
  printf '%s\n' "error: unsupported command '$COMMAND' (supported: apply, install-deps)" >&2
  exit 1
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

load_bootstrap_versions
bootstrap_nix_if_missing

printf '%s\n' "Installing bootstrap-managed dependencies..."
nix --extra-experimental-features "nix-command flakes" profile install "$REPO_ROOT/src#bootstrap-deps"

if [ "$COMMAND" = "apply" ]; then
  printf '%s\n' "Running apply flow via src#apply..."
  nix --extra-experimental-features "nix-command flakes" run "$REPO_ROOT/src#apply"
  exit 0
fi

printf '%s\n' "Bootstrap complete. Run 'nix run ./src#apply' to configure this host."
