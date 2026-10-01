#!/usr/bin/env bash
# Derive age secret identity from SSH host key and write to the nucleus sops age dir.
# Invoked from system activation (runs as root).
#
# Owner spec (arg 2):
#   user:<name>  - single-user readable file (mode 0600), used on nix-darwin
#   group:<name> - root:group shared file (mode 0640), used on NixOS for every
#                  managed user in nucleus-sops
#
# Personal SSH keys stay the per-user decrypt fallback via decrypt-sops.sh.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_dha_ssh_to_age_bin="$1"
_dha_owner_spec="$2"

age_key_file="$(nucleus_machine_age_key_path)"
age_dir="$(dirname -- "$age_key_file")"
host_ssh_key="/etc/ssh/ssh_host_ed25519_key"

if [ ! -f "$host_ssh_key" ]; then
  warn -l sops "/etc/ssh/ssh_host_ed25519_key absent; skipping age key derivation." "This machine cannot decrypt SOPS secrets as a device age recipient" "until the host key is present and registered in .sops.yaml."
else
  mkdir -p "$age_dir"
  # WHY: without -private-key, ssh-to-age's -i reads a public key file and
  # outputs an age public key, which is the wrong thing for an identity file.
  # Activation runs as root, so it reads the 0600 root-owned key directly.
  derived_age_key_exit=0
  derived_age_key="$("$_dha_ssh_to_age_bin" -private-key -i "$host_ssh_key")" || derived_age_key_exit=$?
  if [ "$derived_age_key_exit" -ne 0 ] || [ -z "$derived_age_key" ]; then
    die -l sops "ssh-to-age failed (exit $derived_age_key_exit) reading $host_ssh_key; $age_key_file not written."
  else
    printf '%s\n' "$derived_age_key" >"$age_key_file"
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
      error -l sops "invalid owner spec '$_dha_owner_spec'; expected user:<name> or group:<name>"
      exit 1
      ;;
    esac
  fi
fi
