#!/usr/bin/env bash
# Derives this machine's age public key from its SSH host public key and
# registers it in .sops.yaml as a new recipient, then rewraps every
# SOPS-encrypted file so the machine can decrypt them on first apply.
# Must run before Nix activation (darwin-rebuild / nixos-rebuild) because
# deriveHostAgeKey writes /etc/sops/age/machine.txt only during activation.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_rak_repo_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --repo-root)
    _rak_repo_root="$2"
    shift 2
    ;;
  *)
    usage_std "$(basename "$0")" "[--repo-root <path>]" "Register machine age key in .sops.yaml"
    exit 2
    ;;
  esac
done

if [ -z "$_rak_repo_root" ]; then
  _rak_repo_root="$(derive_repo_root)"
fi

# Why before darwin-rebuild / nixos-rebuild:
#   deriveHostAgeKey (posix-sops.nix) writes /etc/sops/age/machine.txt
#   only after the system activation completes.  On the first apply the
#   machine key must already be a .sops.yaml recipient before sops-nix
#   attempts to decrypt secrets.  The SSH host public key is created by
#   the OS at install time and is available before any Nix activation.
#
# Prerequisites:
#   - /etc/ssh/ssh_host_ed25519_key.pub must exist (OS-generated)
#   - The primary GPG key must be in the keyring so sops updatekeys can
#     re-encrypt data keys for all recipients including the new machine
#   - ssh-to-age and sops must be on PATH (provided by mkApplyApp runtimeInputs)
#   - .sops.yaml must contain the marker comment on its own line:
#       "    # -- machine keys end; personal SSH backup key below --"
_rak_host_pub="/etc/ssh/ssh_host_ed25519_key.pub"
_rak_sops_yaml="$_rak_repo_root/.sops.yaml"

if [ ! -f "$_rak_host_pub" ]; then
  warn -l sops "$_rak_host_pub not found; skipping machine age key auto-registration."
  exit 0
fi

_rak_age_pub=""
if ! _rak_age_pub="$(ssh-to-age -i "$_rak_host_pub")"; then
  die -l sops "ssh-to-age failed to derive age public key from $_rak_host_pub."
fi
if [ -z "$_rak_age_pub" ]; then
  die -l sops "ssh-to-age returned an empty age public key for $_rak_host_pub."
fi

if grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
  say -l sops "machine age key already registered in .sops.yaml; skipping auto-registration."
  exit 0
fi

say -l sops "registering machine age key in .sops.yaml and rewrapping SOPS files..."

_rak_tmp="$(mktemp)"
awk -v age_pub="$_rak_age_pub" '
  /    # -- machine keys end; personal SSH backup key below --/ { print "    - " age_pub }
  { print }
' "$_rak_sops_yaml" >"$_rak_tmp"
chmod 644 "$_rak_tmp"
mv "$_rak_tmp" "$_rak_sops_yaml"

if ! grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
  die -l sops "failed to insert machine age key into .sops.yaml; is the marker comment present?"
fi

for _rak_secret in \
  "$_rak_repo_root"/src/secrets/users/*.yml; do
  if [ ! -f "$_rak_secret" ]; then
    continue
  fi
  if ! sops updatekeys --yes "$_rak_secret"; then
    die -l sops "sops updatekeys failed for $_rak_secret.
sops: Ensure the primary GPG key is imported first:
sops:   gpg --import <backup-key-file>"
  fi
done

# Rewrap wallpaper blobs (enumerated at runtime; count is unknown at script
# parse time).  Read from a temp-file list rather than a pipe so that a
# `sops updatekeys` failure exits the outer script via set -eu; exit 1
# inside a pipe subshell would be silently swallowed.
if [ -d "$_rak_repo_root/src/users" ]; then
  _rak_wallpaper_list="$(mktemp)"
  find "$_rak_repo_root/src/users" -path '*/wallpapers/encrypted/*.sops' -type f \
    >"$_rak_wallpaper_list"
  while IFS= read -r _rak_wallpaper; do
    if ! sops updatekeys --yes "$_rak_wallpaper"; then
      # Temp file is not explicitly removed here because exit 1 terminates
      # the script immediately; the OS reclaims /tmp files on reboot.
      # Removing it inside the read-loop body would trigger SC2094 (the
      # same variable appears in both `rm` and `done < file`).
      die -l sops "sops updatekeys failed for $_rak_wallpaper.
sops: Ensure the primary GPG key is imported first:
sops:   gpg --import <backup-key-file>"
    fi
  done <"$_rak_wallpaper_list"
  rm -f "$_rak_wallpaper_list"
fi

say -l sops "machine age key registered and SOPS files rewrapped."
say -l sops "Commit the changes before deploying to other machines:"
say -l sops "  git add .sops.yaml src/secrets src/users"
say -l sops "  git commit -m \"chore: register <hostname> machine age key\""
