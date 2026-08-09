#!/usr/bin/env bash
# Reads identity from SOPS decrypted secret and writes to ~/.config/git/identity.

set -euo pipefail

_git_secret_path="$1"
_git_bin="$2"

if [ ! -f "$_git_secret_path" ]; then
  echo "git-identity: missing decrypted Git identity secret at $_git_secret_path." >&2
  exit 1
fi

identity_name="$(/usr/bin/grep -m1 '^name=' "$_git_secret_path" | /usr/bin/cut -d '=' -f 2-)"
identity_email="$(/usr/bin/grep -m1 '^email=' "$_git_secret_path" | /usr/bin/cut -d '=' -f 2-)"
identity_signing_key="$(/usr/bin/grep -m1 '^signingKey=' "$_git_secret_path" | /usr/bin/cut -d '=' -f 2-)"

if [ -z "$identity_name" ] || [ -z "$identity_email" ] || [ -z "$identity_signing_key" ]; then
  echo "git-identity: git identity payload must include name/email/signingKey entries." >&2
  exit 1
fi

# Write to the dedicated identity include file, not to the HM-managed config.
identity_file="$HOME/.config/git/identity"
mkdir -p "$(dirname "$identity_file")"
"$_git_bin" config --file "$identity_file" user.name "$identity_name"
"$_git_bin" config --file "$identity_file" user.email "$identity_email"
"$_git_bin" config --file "$identity_file" user.signingkey "$identity_signing_key"
# Restrict the identity include file to owner-read-only: it contains the
# GPG signing key reference, which minimises visibility to other local users.
chmod 600 "$identity_file"
