#!/usr/bin/env bash
# src/scripts/register-host-age-key.sh — Register machine age key in .sops.yaml for SOPS access.
#
# Derives this machine's age public key from its SSH host public key and
# registers it in .sops.yaml as a new recipient, then rewraps every
# SOPS-encrypted file so the machine can decrypt them on first apply.
# Must run before Nix activation (darwin-rebuild / nixos-rebuild) because
# deriveHostAgeKey writes /etc/sops/age/machine.txt only during activation.
#
# Arguments:
#   --repo-root <path>  Override detected repository root (default: auto-detected via resolve_nucleus_root).
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path (default: auto-detected).
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
  resolve_nucleus_root() {
    [ -n "${NUCLEUS_REPO_ROOT:-}" ] && [ -d "$NUCLEUS_REPO_ROOT" ] && { printf '%s\n' "$NUCLEUS_REPO_ROOT"; return 0; }
    printf '%s\n' "${HOME}/dev/nucleus"
  }
fi

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
  _rak_repo_root="$(resolve_nucleus_root)"
fi

# Derive this machine's age public key from its SSH host public key and
# register it in .sops.yaml as a new recipient, then rewrap every
# SOPS-encrypted file so the machine can decrypt them on the first apply.
#
# Why run before darwin-rebuild / nixos-rebuild:
#   deriveHostAgeKey (posix-sops.nix) writes /etc/sops/age/machine.txt
#   only after the system activation completes.  On the first apply the
#   machine key must already be a .sops.yaml recipient before sops-nix
#   attempts to decrypt secrets.  The SSH host public key is created by
#   the OS at install time and is available before any Nix activation.
#
# Idempotency: if the derived age public key is already present in
#   .sops.yaml the function returns immediately (no file is modified).
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
  printf 'sops: %s not found; skipping machine age key auto-registration.\n' \
    "$_rak_host_pub" >&2
  exit 0
fi

# Derive the age public key from the SSH host public key (public-key
# conversion; no passphrase or private key material is accessed).
_rak_age_pub=""
if ! _rak_age_pub="$(ssh-to-age -i "$_rak_host_pub")"; then
  printf 'sops: ERROR — ssh-to-age failed to derive age public key from %s.\n' \
    "$_rak_host_pub" >&2
  exit 1
fi
if [ -z "$_rak_age_pub" ]; then
  printf 'sops: ERROR — ssh-to-age returned an empty age public key for %s.\n' \
    "$_rak_host_pub" >&2
  exit 1
fi

# Idempotency: skip insertion and rewrap when this machine is already registered.
if grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
  printf 'sops: machine age key already registered in .sops.yaml; skipping auto-registration.\n'
  exit 0
fi

printf 'sops: registering machine age key in .sops.yaml and rewrapping SOPS files...\n'

# Insert the new age key line immediately before the marker comment.
# The marker delineates machine recipients from the personal SSH backup key
# so new machines are always inserted above the backup entry.
# A temp file is used so an interrupted write cannot corrupt .sops.yaml.
_rak_tmp="$(mktemp)"
awk -v age_pub="$_rak_age_pub" '
  /    # -- machine keys end; personal SSH backup key below --/ { print "    - " age_pub }
  { print }
' "$_rak_sops_yaml" > "$_rak_tmp"
# mktemp creates files at mode 0600; .sops.yaml is a config file (not a
# secret) and must be 0644 so other tools can read the recipient list.
# Set the mode before the atomic rename so the file is never visible at 0600.
chmod 644 "$_rak_tmp"
mv "$_rak_tmp" "$_rak_sops_yaml"

# Verify the insertion succeeded; catches the case where the marker comment
# was removed or mistyped.
if ! grep -qF "$_rak_age_pub" "$_rak_sops_yaml"; then
  printf 'sops: ERROR — failed to insert machine age key into .sops.yaml; is the marker comment present?\n' >&2
  exit 1
fi

# Rewrap all SOPS-encrypted files so the new machine recipient can decrypt
# them.  Requires the primary GPG key in the keyring for re-encryption.
# The --yes flag skips the interactive "update recipients" confirmation.
for _rak_secret in \
    "$_rak_repo_root/src/secrets/users-"*.yml \
    "$_rak_repo_root/src/secrets/git-identities.yml" \
    "$_rak_repo_root/src/secrets/gpg-personal.yml" \
    "$_rak_repo_root/src/secrets/ssh-personal.yml"; do
  if [ ! -f "$_rak_secret" ]; then
    continue
  fi
  if ! sops updatekeys --yes "$_rak_secret"; then
    printf 'sops: ERROR — sops updatekeys failed for %s.\n' "$_rak_secret" >&2
    printf 'sops: Ensure the primary GPG key is imported first:\n' >&2
    printf 'sops:   gpg --import <backup-key-file>\n' >&2
    exit 1
  fi
done

# Rewrap wallpaper blobs (enumerated at runtime; count is unknown at script
# parse time).  Read from a temp-file list rather than a pipe so that a
# `sops updatekeys` failure exits the outer script via set -eu; exit 1
# inside a pipe subshell would be silently swallowed.
if [ -d "$_rak_repo_root/src/assets/wallpapers" ]; then
  _rak_wallpaper_list="$(mktemp)"
  find "$_rak_repo_root/src/assets/wallpapers" -name "*.sops" -type f \
    > "$_rak_wallpaper_list"
  while IFS= read -r _rak_wallpaper; do
    if ! sops updatekeys --yes "$_rak_wallpaper"; then
      # Temp file is not explicitly removed here because exit 1 terminates
      # the script immediately; the OS reclaims /tmp files on reboot.
      # Removing it inside the read-loop body would trigger SC2094 (the
      # same variable appears in both `rm` and `done < file`).
      printf 'sops: ERROR — sops updatekeys failed for %s.\n' "$_rak_wallpaper" >&2
      printf 'sops: Ensure the primary GPG key is imported first:\n' >&2
      printf 'sops:   gpg --import <backup-key-file>\n' >&2
      exit 1
    fi
  done < "$_rak_wallpaper_list"
  rm -f "$_rak_wallpaper_list"
fi

printf 'sops: machine age key registered and SOPS files rewrapped.\n'
printf 'sops: Commit the changes before deploying to other machines:\n'
printf 'sops:   git add .sops.yaml src/secrets src/assets/wallpapers\n'
printf 'sops:   git commit -m "chore: register <hostname> machine age key"\n'
