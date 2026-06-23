#!/usr/bin/env bash
# Ensures /etc/ssh/ssh_host_ed25519_key exists so that
# register-host-age-key.sh can derive the machine age public key from it.
# On freshly provisioned machines the OS may not have generated host keys
# yet; ssh-keygen -A creates all standard host key types.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

usage() {
  usage_std "$(basename "$0")" "" "Generate SSH host keys if missing. No arguments accepted."
  cat <<'EOF'
  -h, --help  Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$(basename "$0")" "$1" >&2
      exit 1
      ;;
  esac
done

_gsk_host_key="/etc/ssh/ssh_host_ed25519_key"

if [ -f "$_gsk_host_key" ]; then
  exit 0
fi

printf 'SSH: %s not found; generating SSH host keys...\n' "$_gsk_host_key"
# Pass PATH explicitly so sudo finds the Nix openssh ssh-keygen.
if ! sudo env "PATH=$PATH" ssh-keygen -A; then
  printf 'SSH: ERROR — ssh-keygen -A failed; cannot generate SSH host keys.\n' >&2
  exit 1
fi

if [ ! -f "$_gsk_host_key" ]; then
  printf 'SSH: ERROR — ssh-keygen -A completed but %s is still absent.\n' \
    "$_gsk_host_key" >&2
  exit 1
fi

printf 'SSH: SSH host keys generated successfully.\n'
