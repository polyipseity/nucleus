#!/usr/bin/env bash
# Derive this machine's age public key from its SSH host public key, register it
# in .sops.yaml, then rewrap every SOPS file so this machine decrypts them on
# first apply.
#
# WHY before darwin-rebuild / nixos-rebuild: derive-host-age-key.sh writes the
# machine age key only after system activation, while sops-nix decrypts during it,
# so the machine key must already be a recipient. The SSH host public key is
# created by the OS at install time.
#
# Prereqs: ssh-to-age and sops on PATH, the primary GPG key in the keyring, and
# the "    # -- machine keys end; personal SSH backup key below --" marker in
# .sops.yaml.

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

# WHY a temp-file list: the wallpaper set is only known at runtime, and a
# `sops updatekeys` failure inside a pipe subshell would be swallowed by set -eu.
if [ -d "$_rak_repo_root/src/users" ]; then
  _rak_wallpaper_list="$(mktemp)"
  find "$_rak_repo_root/src/users" -path '*/wallpapers/encrypted/*.sops' -type f \
    >"$_rak_wallpaper_list"
  while IFS= read -r _rak_wallpaper; do
    if ! sops updatekeys --yes "$_rak_wallpaper"; then
      # WHY no rm: exit 1 ends the script and the OS reclaims /tmp on reboot. Removing
      # it in the read-loop body would trip SC2094.
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
