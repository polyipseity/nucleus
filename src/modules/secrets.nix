# modules/secrets.nix — Home Manager activation hook that decrypts SOPS secrets
# and materialises SSH private keys and GPG keys into the user's home directory.
#
# Secret layout expected in secrets/*.yml:
#   ssh_keys:    list of { name, value } — written to ~/.ssh/<name> (chmod 600)
#   gpg_imports: list of { name, value } — ASCII-armored keys imported into the
#                                           user's GPG keyring
#
# Decryption key priority:
#   1. Host SSH key (/etc/ssh/ssh_host_ed25519_key) — available after first boot
#   2. GPG keyring fallback — used on a fresh install before the host key exists
{ config, lib, pkgs, ... }:
let
  # Path to the ed25519 host key used as the SOPS age recipient.
  hostSshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  # Nix store path of the checked-in secrets directory (evaluated at build time).
  secretsDir = ../../secrets;
  # Enumerate directory entries at eval time to drive assertions.
  secretEntries =
    if builtins.pathExists secretsDir then builtins.attrNames (builtins.readDir secretsDir)
    else [ ];
  # True when at least one *.yml file exists inside the secrets directory.
  hasEncryptedSecretFiles = lib.any (name: lib.hasSuffix ".yml" name) secretEntries;
in
{
  # Fail fast at eval time if the repo is missing the expected secrets tree.
  assertions = [
    {
      assertion = builtins.pathExists secretsDir;
      message = "nucleus: required secrets directory is missing at ${toString secretsDir}.";
    }
    {
      assertion = hasEncryptedSecretFiles;
      message = "nucleus: no encrypted secret files (*.yml) found under ${toString secretsDir}.";
    }
  ];

  # Runs after writeBoundary (i.e. after all symlinks are in place) so that
  # SSH keys are available before any subsequent activation steps that need them.
  home.activation.nucleusKeyProvision = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    export HOME="${config.home.homeDirectory}"

    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # nucleus_decrypt FILE OUTPUT
    # Attempts SOPS decryption via the host SSH key first; falls back to the
    # GPG keyring if the host key file does not exist.
    nucleus_decrypt() {
      if [ -f "${hostSshKeyPath}" ]; then
        SOPS_AGE_SSH_PRIVATE_KEY_FILE="${hostSshKeyPath}" \
          ${pkgs.sops}/bin/sops --decrypt --output-format json "$1" > "$2" 2>/dev/null \
          && return 0
      fi
      ${pkgs.sops}/bin/sops --decrypt --output-format json "$1" > "$2"
    }

    for secrets_file in "${secretsDir}"/*.yml; do
      [ -e "$secrets_file" ] || continue

      tmp_json="$(mktemp)"
      if nucleus_decrypt "$secrets_file" "$tmp_json"; then
        # Write each SSH key only when the on-disk value differs (avoids
        # unnecessary permission changes that would revoke agent-loaded keys).
        ${pkgs.jq}/bin/jq -c '.ssh_keys[]?' "$tmp_json" | while IFS= read -r entry; do
          key_name="$(printf '%s' "$entry" | ${pkgs.jq}/bin/jq -r '.name')"
          key_path="$HOME/.ssh/$key_name"
          key_value="$(printf '%s' "$entry" | ${pkgs.jq}/bin/jq -r '.value')"

          if [ ! -f "$key_path" ] || [ "$(cat "$key_path" 2>/dev/null || true)" != "$key_value" ]; then
            printf '%s\n' "$key_value" > "$key_path"
            chmod 600 "$key_path"
          fi
        done

        # Import GPG material in batch mode; errors are suppressed because keys
        # that are already present cause gpg to exit non-zero.
        tmp_gpg="$(mktemp)"
        ${pkgs.jq}/bin/jq -r '.gpg_imports[]?.value' "$tmp_json" > "$tmp_gpg"
        if [ -s "$tmp_gpg" ]; then
          ${pkgs.gnupg}/bin/gpg --batch --import "$tmp_gpg" >/dev/null 2>&1 || true
        fi
        rm -f "$tmp_gpg"
      else
        echo "nucleus: failed to decrypt $(basename "$secrets_file"); skipping." >&2
      fi

      rm -f "$tmp_json"
    done
  '';
}
