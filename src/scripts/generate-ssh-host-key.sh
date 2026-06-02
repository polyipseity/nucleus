#!/usr/bin/env sh
# src/scripts/generate-ssh-host-key.sh — Ensure /etc/ssh/ssh_host_ed25519_key exists
# Exit: 0 success, 1 error
set -eu

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
