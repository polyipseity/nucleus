# Reads identity from SOPS decrypted secret and writes to ~/.config/git/identity.
# Requires: GIT_SECRET_PATH, GIT_BIN env vars.

if [ ! -f "$GIT_SECRET_PATH" ]; then
  echo "gitIdentityFromSops: missing decrypted Git identity secret at $GIT_SECRET_PATH." >&2
  exit 1
fi

identity_name="$(/usr/bin/grep -m1 '^name=' "$GIT_SECRET_PATH" | /usr/bin/cut -d '=' -f 2-)"
identity_email="$(/usr/bin/grep -m1 '^email=' "$GIT_SECRET_PATH" | /usr/bin/cut -d '=' -f 2-)"
identity_signing_key="$(/usr/bin/grep -m1 '^signingKey=' "$GIT_SECRET_PATH" | /usr/bin/cut -d '=' -f 2-)"

if [ -z "$identity_name" ] || [ -z "$identity_email" ] || [ -z "$identity_signing_key" ]; then
  echo "gitIdentityFromSops: git identity payload must include name/email/signingKey entries." >&2
  exit 1
fi

# Write to the dedicated identity include file, not to the HM-managed config.
identity_file="$HOME/.config/git/identity"
mkdir -p "$(dirname "$identity_file")"
"$GIT_BIN" config --file "$identity_file" user.name "$identity_name"
"$GIT_BIN" config --file "$identity_file" user.email "$identity_email"
"$GIT_BIN" config --file "$identity_file" user.signingkey "$identity_signing_key"
# Restrict the identity include file to owner-read-only: it contains the
# GPG signing key reference, which minimises visibility to other local users.
chmod 600 "$identity_file"
