{ config, lib, pkgs, ... }:
let
  hostSshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  secretsDir = ../../secrets;
  secretEntries =
    if builtins.pathExists secretsDir then builtins.attrNames (builtins.readDir secretsDir)
    else [ ];
  hasEncryptedSecretFiles = lib.any (name: lib.hasSuffix ".yml" name) secretEntries;
in
{
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

  home.activation.nucleusKeyProvision = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    export HOME="${config.home.homeDirectory}"

    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

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
        ${pkgs.jq}/bin/jq -c '.ssh_keys[]?' "$tmp_json" | while IFS= read -r entry; do
          key_name="$(printf '%s' "$entry" | ${pkgs.jq}/bin/jq -r '.name')"
          key_path="$HOME/.ssh/$key_name"
          key_value="$(printf '%s' "$entry" | ${pkgs.jq}/bin/jq -r '.value')"

          if [ ! -f "$key_path" ] || [ "$(cat "$key_path" 2>/dev/null || true)" != "$key_value" ]; then
            printf '%s\n' "$key_value" > "$key_path"
            chmod 600 "$key_path"
          fi
        done

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
