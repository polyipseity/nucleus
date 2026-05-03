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
#       -----BEGIN OPENSSH PRIVATE KEY-----
#       ...
#       -----END OPENSSH PRIVATE KEY-----
#
#   gpg-personal.yml:
#     gpg_personal_<username>: |
#       -----BEGIN PGP PRIVATE KEY BLOCK-----
#       ...
#       -----END PGP PRIVATE KEY BLOCK-----
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
    sopsFile = ../../secrets/ssh-personal.yml;
    path = "${config.home.homeDirectory}/.ssh/${sshSecretName}";
    mode = "0600";
  };

  # --------------------------------------------------------------------------
  # GPG key material — sops-nix decrypts to its managed path (tmpfs on Linux).
  # The activation hook below imports it into the keyring.
  # --------------------------------------------------------------------------
  sops.secrets."${gpgSecretName}" = {
    sopsFile = ../../secrets/gpg-personal.yml;
    # No explicit path — let sops-nix manage it (typically /run/user/<uid>/…
    # on Linux, or ~/Library/… on macOS; both are outside persistent storage).
  };

  # Static SSH IdentityFile config snippet.
  # Activate with: Include ~/.ssh/config.d/* in ~/.ssh/config
  home.file.".ssh/config.d/nucleus" = {
    text = ''
      # Managed by nucleus — do not edit manually.
      Host *
        IdentityFile ~/.ssh/${sshSecretName}
    '';
    mode = "0600";
  };

  # --------------------------------------------------------------------------
  # GPG import — the only remaining imperative activation step.
  # Runs after sops-nix (setupSecrets) has written the decrypted key to
  # config.sops.secrets.${gpgSecretName}.path.
  # gpg --import is idempotent; non-zero exit for already-present keys is
  # suppressed.
  # --------------------------------------------------------------------------
  home.activation.nucleusGpgImport = lib.hm.dag.entryAfter [ "writeBoundary" "setupSecrets" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"

    if [ -f "${config.sops.secrets.${gpgSecretName}.path}" ]; then
      ${pkgs.gnupg}/bin/gpg --batch --import "${config.sops.secrets.${gpgSecretName}.path}" \
        >/dev/null 2>&1 || true
    fi
  '';
}
