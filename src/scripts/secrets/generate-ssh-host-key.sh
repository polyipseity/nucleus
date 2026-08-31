#!/usr/bin/env bash
# Verify /etc/ssh/ssh_host_ed25519_key exists so that
# register-host-age-key.sh can derive the machine age public key from it.
# On freshly provisioned machines the OS may not have generated host keys
# yet; ssh-keygen -A creates all standard host key types.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

usage() {
  usage_std "$(basename "$0")" "" "Generate SSH host keys if missing. No arguments accepted."
  cat <<'EOF'
  -h, --help  Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  *)
    error "unknown argument: $1"
    exit 1
    ;;
  esac
done

_gsk_host_key="/etc/ssh/ssh_host_ed25519_key"

if [ -f "$_gsk_host_key" ]; then
  exit 0
fi

say -l SSH "$_gsk_host_key not found; generating SSH host keys..."
# Pass PATH explicitly so sudo finds the Nix openssh ssh-keygen.
if ! sudo env "PATH=$PATH" ssh-keygen -A; then
  die -l SSH "ssh-keygen -A failed; cannot generate SSH host keys."
fi

if [ ! -f "$_gsk_host_key" ]; then
  die -l SSH "ssh-keygen -A completed but $_gsk_host_key is still absent."
fi

say -l SSH "SSH host keys generated successfully."
