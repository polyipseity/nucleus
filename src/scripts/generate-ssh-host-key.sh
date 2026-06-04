#!/usr/bin/env bash
# src/scripts/generate-ssh-host-key.sh — Ensure SSH host key exists before SOPS registration.
#
# Ensures /etc/ssh/ssh_host_ed25519_key exists so that
# register-host-age-key.sh can derive the machine age public key from it.
# On freshly provisioned machines the OS may not have generated host keys
# yet; ssh-keygen -A creates all standard host key types.
#
# Arguments:
#   (none)        No arguments accepted.
#
# Environment variables:
#   (none)        No environment variables used.
#
# Exit conditions:
#   0 on success; 1 on error.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/lib.sh" ]; then
  . "$SCRIPT_DIR/lib.sh"
else
  usage_std() {
    printf 'usage: %s %s\n' "$1" "${2:-}"
    [ "$#" -gt 2 ] && printf '  %s\n' "$3"
  }
fi

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

# Ensure /etc/ssh/ssh_host_ed25519_key exists before
# register_host_age_key_if_needed tries to derive the machine age public key
# from it.  On freshly provisioned machines the OS may not have generated host
# keys yet; ssh-keygen -A creates all standard host key types without
# overwriting any that already exist, making this call idempotent.
#
# Why before register_host_age_key_if_needed:
#   register_host_age_key_if_needed derives the machine age public key from
#   /etc/ssh/ssh_host_ed25519_key.pub.  If the key does not exist it skips
#   registration silently, so the machine can never decrypt its own SOPS
#   secrets until the operator re-runs apply after the OS has generated the
#   key.  Generating it here makes first-apply fully self-contained.
#
# Requires: sudo session already acquired (start_sudo_keepalive must have
#   been called before this script).
# PATH: ssh-keygen is provided by openssh in mkApplyApp runtimeInputs.
#   The sudo invocation carries PATH explicitly so the Nix-wrapped binary
#   is found even after sudo resets the environment.

_gsk_host_key="/etc/ssh/ssh_host_ed25519_key"

if [ -f "$_gsk_host_key" ]; then
  exit 0
fi

printf 'SSH: %s not found; generating SSH host keys...\n' "$_gsk_host_key"
# Pass PATH explicitly so sudo finds the Nix openssh ssh-keygen rather than
# any older system ssh-keygen that may be shadowed by runtimeInputs.
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
