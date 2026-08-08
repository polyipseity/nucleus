#!/usr/bin/env bash
# Derive age secret identity from SSH host key and write to /etc/sops/age/machine.txt.
# Invoked from system activation (runs as root).
#
# Owner spec (arg 2):
#   user:<name>  — single-user readable file (mode 0600), used on nix-darwin.
#   group:<name> — root:group shared file (mode 0640), used on NixOS for all
#                  managed users in nucleus-sops.
#
# Personal SSH keys remain the per-user decrypt fallback via decrypt-sops.sh
# manifest scan.
set -euo pipefail

_dha_ssh_to_age_bin="$1"
_dha_owner_spec="$2"

age_dir="/etc/sops/age"
age_key_file="$age_dir/machine.txt"
host_ssh_key="/etc/ssh/ssh_host_ed25519_key"

if [ ! -f "$host_ssh_key" ]; then
  echo "sops: /etc/ssh/ssh_host_ed25519_key absent; skipping age key derivation." >&2
  echo "sops:   This machine cannot decrypt SOPS secrets as a device age recipient" >&2
  echo "sops:   until the host key is present and registered in .sops.yaml." >&2
else
  mkdir -p "$age_dir"
  # ssh-to-age -private-key -i reads an SSH private key FILE and outputs
  # the age private identity (AGE-SECRET-KEY-...).  Without -private-key,
  # -i reads a public key file and outputs an age public key — wrong for
  # an identity file.  System activation runs as root so it can read the
  # 0600 root-owned private key directly.
  derived_age_key_exit=0
  derived_age_key="$("$_dha_ssh_to_age_bin" -private-key -i "$host_ssh_key")" || derived_age_key_exit=$?
  if [ "$derived_age_key_exit" -ne 0 ] || [ -z "$derived_age_key" ]; then
    echo "sops: ssh-to-age failed (exit $derived_age_key_exit) reading $host_ssh_key; $age_key_file not written." >&2
  else
    printf '%s\n' "$derived_age_key" > "$age_key_file"
    case "$_dha_owner_spec" in
      group:*)
        chown "root:${_dha_owner_spec#group:}" "$age_key_file"
        chmod 0640 "$age_key_file"
        ;;
      user:*)
        chown "${_dha_owner_spec#user:}" "$age_key_file"
        chmod 0600 "$age_key_file"
        ;;
      *)
        echo "sops: invalid owner spec '$_dha_owner_spec'; expected user:<name> or group:<name>" >&2
        exit 1
        ;;
    esac
  fi
fi
