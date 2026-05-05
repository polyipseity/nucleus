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
#     ssh_personal_<username>_pub: |
#       ssh-ed25519 AAAA... user@host
#     ssh_personal_<username>_rsa: |
#       -----BEGIN NOT OPENSSH PRIVATE KEY-----
#       ...
#       -----END NOT OPENSSH PRIVATE KEY-----
#     ssh_personal_<username>_rsa_pub: |
#       ssh-rsa AAAA... user@host
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
#   3. Once SSH host keys exist on this machine, derive its age recipient and
#      add it to .sops.yaml keys.age_devices, then rewrap encrypted files:
#        ssh-to-age < /etc/ssh/ssh_host_ed25519.pub
#        sops updatekeys src/secrets/ssh-personal.yml
#        sops updatekeys src/secrets/gpg-personal.yml
#      After this step sops-nix uses the machine SSH key and GPG is no longer
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
  sshPublicSecretName = "${sshSecretName}_pub";
  sshRsaSecretName = "${sshSecretName}_rsa";
  sshRsaPublicSecretName = "${sshRsaSecretName}_pub";
  sshPrivateKeyPath = "${config.home.homeDirectory}/.ssh/${sshSecretName}";
  sshPublicKeyPath = "${sshPrivateKeyPath}.pub";
  sshRsaPrivateKeyPath = "${config.home.homeDirectory}/.ssh/${sshRsaSecretName}";
  sshRsaPublicKeyPath = "${sshRsaPrivateKeyPath}.pub";
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
  # age: machine SSH key — works once keys.age_devices is populated in .sops.yaml.
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
  # SSH public key — declaratively sourced from SOPS to avoid activation-time
  # key derivation and passphrase handling edge cases.
  # --------------------------------------------------------------------------
  sops.secrets."${sshPublicSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshPublicKeyPath;
    mode = "0644";
  };

  # --------------------------------------------------------------------------
  # SSH RSA keypair (legacy fallback) — still materialized for compatibility
  # with environments that have not migrated off RSA yet, but intentionally not
  # referenced by the default SSH match blocks below.
  # --------------------------------------------------------------------------
  sops.secrets."${sshRsaSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshRsaPrivateKeyPath;
    mode = "0600";
  };

  sops.secrets."${sshRsaPublicSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshRsaPublicKeyPath;
    mode = "0644";
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
  # GPG import — the only remaining imperative activation step.
  # Runs after sops-nix has materialized decrypted secret files.
  # gpg --import is idempotent, so repeated activations are safe.
  #
  # Trust bootstrap invariant:
  #   If the keyring had no secret keys before this import, treat the first key
  #   carried by the managed secret blob as the user's primary key and assign it
  #   ultimate ownertrust. This avoids an ambiguous trustdb state on new hosts
  #   while keeping reruns deterministic.
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

    # Capture pre-import state so we only bootstrap ownertrust on first-key
    # initialization for this user profile.
    secret_key_count_before="$(${pkgs.gnupg}/bin/gpg --list-secret-keys --with-colons 2>/dev/null | /usr/bin/awk -F: '$1 == "sec" { count += 1 } END { print count + 0 }')"
    first_key_fingerprint="$(${pkgs.gnupg}/bin/gpg --batch --import-options show-only --dry-run --with-colons --import "${config.sops.secrets.${gpgSecretName}.path}" 2>/dev/null | /usr/bin/awk -F: '$1 == "fpr" { print $10; exit }')"

    if ! ${pkgs.gnupg}/bin/gpg --import "${config.sops.secrets.${gpgSecretName}.path}"; then
      echo "nucleus: gpg import failed for ${gpgSecretName}." >&2
      exit 1
    fi

    if [ "$secret_key_count_before" -eq 0 ]; then
      if [ -z "$first_key_fingerprint" ]; then
        echo "nucleus: imported first GPG keyring material but could not determine a fingerprint for ownertrust bootstrap." >&2
        exit 1
      fi

      if ! printf '%s:6:\n' "$first_key_fingerprint" | ${pkgs.gnupg}/bin/gpg --import-ownertrust; then
        echo "nucleus: failed to assign ultimate ownertrust to $first_key_fingerprint during first-key bootstrap." >&2
        exit 1
      fi
    fi
  '';
}
