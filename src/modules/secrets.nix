# modules/secrets.nix — Secret management for Home Manager.
#
# All decryption is delegated to sops-nix (sops.secrets). The only remaining
# imperative step is `gpg --import`, which mutates the keyring and has no
# declarative equivalent.
#
# Required SOPS file format (flat top-level keys):
#
#   ssh-personal.yml:
#     ssh_personal_<username>: |
#       -----BEGIN NOT OPENSSH PRIVATE KEY-----
#       ...
#       -----END NOT OPENSSH PRIVATE KEY-----
#
#   gpg-personal.yml:
#     gpg_personal_<username>: |
#       -----BEGIN NOT PGP PRIVATE KEY BLOCK-----
#       ...
#       -----END NOT PGP PRIVATE KEY BLOCK-----
#
# To flatten the existing nested-array format, run on a machine with the GPG
# key already in the keyring:
#   sops edit src/secrets/ssh-personal.yml   # restructure to flat format above
#   sops edit src/secrets/gpg-personal.yml   # restructure to flat format above
#
# Bootstrap (once per fresh machine):
#   1. Import your primary GPG key manually:
#        gpg --import <key-export>
#   2. Run: home-manager switch
#      sops-nix uses GPG to decrypt on first activation.
#   3. Once the SSH key is materialised, derive the host age key and add it to
#      .sops.yaml, then re-encrypt both files:
#        ssh-keyscan <host> | ssh-to-age   # get age pubkey
#        # fill in .sops.yaml age anchors, uncomment them
#        sops updatekeys src/secrets/ssh-personal.yml
#        sops updatekeys src/secrets/gpg-personal.yml
#      After this step sops-nix uses the host SSH key and GPG is no longer
#      required as the primary decryption path.
{ config, lib, pkgs, username ? null, ... }:
let
  primaryUsername =
    if username == null then
      throw "modules/secrets.nix requires `username` in extraSpecialArgs to enforce primary-user-only secrets."
    else
      username;

  isPrimaryUser = config.home.username == primaryUsername;
  gpgSecretName = "gpg_personal_${primaryUsername}";
  sshSecretName = "ssh_personal_${primaryUsername}";
  sshPrivateKeyPath = "${config.home.homeDirectory}/.ssh/${sshSecretName}";
  sshPublicKeyPath = "${sshPrivateKeyPath}.pub";
  sshIdentityFile = "~/.ssh/${sshSecretName}";
  sshExtraOptions =
    {
      AddKeysToAgent = "yes";
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      UseKeychain = "yes";
    };
in
lib.mkIf isPrimaryUser {
  # Register both decryption backends for the HM sops-nix module.
  # age: host SSH key — works once age recipients are added to .sops.yaml.
  # gpg: fallback using the keyring populated by the bootstrap step above.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.gnupg.home = "${config.home.homeDirectory}/.gnupg";

  # --------------------------------------------------------------------------
  # SSH private key — sops-nix owns decryption, file write, and chmod 600.
  # --------------------------------------------------------------------------
  sops.secrets."${sshSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshPrivateKeyPath;
    mode = "0600";
  };

  # --------------------------------------------------------------------------
  # GPG key material — sops-nix decrypts to its managed path (tmpfs on Linux).
  # The activation hook below imports it into the keyring.
  # --------------------------------------------------------------------------
  sops.secrets."${gpgSecretName}" = {
    sopsFile = ../secrets/gpg-personal.yml;
    # No explicit path — let sops-nix manage it (typically /run/user/<uid>/…
    # on Linux, or ~/Library/… on macOS; both are outside persistent storage).
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        identityFile = sshIdentityFile;
        extraOptions = sshExtraOptions;
      };

      "github.com" = {
        hostname = "github.com";
        identityFile = sshIdentityFile;
        extraOptions = sshExtraOptions;
      };
    };
  };

  # --------------------------------------------------------------------------
  # SSH public key derivation — keep the public key synchronized with
  # the declaratively managed private key so GitHub SSH auth works without any
  # manual key-export steps after activation.
  #
  # Uses a non-interactive ssh-keygen invocation (`-P ""`) so activation never
  # blocks on a passphrase prompt. If the private key is passphrase-protected,
  # public-key derivation is treated as best-effort and emits a warning instead
  # of failing the whole activation.
  # --------------------------------------------------------------------------
  home.activation.sshPublicKeyFromPrivate = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    key_source=""
    if [ -f "${sshPrivateKeyPath}" ]; then
      key_source="${sshPrivateKeyPath}"
    elif [ -f "${config.sops.secrets.${sshSecretName}.path}" ]; then
      # During early activation ordering, the stable ~/.ssh symlink may not be
      # present yet even though sops-nix has already materialized the secret.
      key_source="${config.sops.secrets.${sshSecretName}.path}"
    fi

    if [ -z "$key_source" ]; then
      echo "nucleus: missing SSH private key at ${sshPrivateKeyPath} (and sops path ${config.sops.secrets.${sshSecretName}.path}); cannot derive public key." >&2
      exit 1
    fi

    tmpPublicKey="$(mktemp)"
    tmpErr="$(mktemp)"
    if ! ${pkgs.openssh}/bin/ssh-keygen -y -P "" -f "$key_source" > "$tmpPublicKey" 2> "$tmpErr"; then
      if /usr/bin/grep -Eqi 'incorrect passphrase|passphrase' "$tmpErr"; then
        if [ -f "${sshPublicKeyPath}" ]; then
          echo "nucleus: SSH key is passphrase-protected; keeping existing public key at ${sshPublicKeyPath}." >&2
        else
          echo "nucleus: SSH key is passphrase-protected; could not derive ${sshPublicKeyPath} non-interactively. Load the key in your agent or remove passphrase, then re-run activation." >&2
        fi
        rm -f "$tmpPublicKey" "$tmpErr"
        exit 0
      fi

      rm -f "$tmpPublicKey"
      rm -f "$tmpErr"
      echo "nucleus: failed to derive SSH public key from $key_source." >&2
      exit 1
    fi

    rm -f "$tmpErr"
    chmod 644 "$tmpPublicKey"
    if [ -f "${sshPublicKeyPath}" ] && /usr/bin/cmp -s "$tmpPublicKey" "${sshPublicKeyPath}"; then
      rm -f "$tmpPublicKey"
    else
      mv "$tmpPublicKey" "${sshPublicKeyPath}"
    fi
  '';

  # --------------------------------------------------------------------------
  # GPG import — the only remaining imperative activation step.
  # Runs after sops-nix has materialized decrypted secret files.
  # gpg --import is idempotent, so repeated activations are safe.
  #
  # NOTE: GnuPG 2.5 + Kyber private key import currently fails with
  # `--batch` (`IPC parameter error`) on this key format. We intentionally use
  # a non-batch import invocation to ensure a successful secret-key import.
  # --------------------------------------------------------------------------
  home.activation.gpgImport = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"

    if [ ! -f "${config.sops.secrets.${gpgSecretName}.path}" ]; then
      echo "nucleus: missing decrypted GPG secret at ${config.sops.secrets.${gpgSecretName}.path}; cannot import key material." >&2
      exit 1
    fi

    if ! ${pkgs.gnupg}/bin/gpg --import "${config.sops.secrets.${gpgSecretName}.path}"; then
      echo "nucleus: gpg import failed for ${gpgSecretName}." >&2
      exit 1
    fi
  '';
}
