# modules/secrets.nix — Secret management for Home Manager.
#
# All decryption is delegated to sops-nix (sops.secrets). Imperative activation
# hooks handle side-effects that have no declarative equivalent:
#   - gpgImport:        imports the managed GPG key and enforces ownertrust
#   - gitIdentityFromSops: writes git name/email/signingkey from SOPS payload
#   - sshKeyAdopt:      tracks the SSH key fingerprint; flushes agent on rotation
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
#   git-identities.yml:
#     git_identity_<username>: |
#       name=Your Name
#       email=your@email.example
#       signingKey=YOUR_GPG_SIGNING_KEY!
#
# To flatten the existing nested-array format, run on a machine with the GPG
# key already in the keyring:
#   sops edit src/secrets/ssh-personal.yml     # restructure to flat format above
#   sops edit src/secrets/gpg-personal.yml     # restructure to flat format above
#   sops edit src/secrets/git-identities.yml   # restructure to flat format above
#
# Bootstrap (once per fresh machine):
#   1. Import your primary GPG key manually:
#        gpg --import <key-export>
#   2. Run: home-manager switch
#      sops-nix uses GPG to decrypt on first activation.
#      The managed primary fingerprint from gpg-personal.yml is assigned
#      ultimate ownertrust on every activation to keep trustdb state
#      deterministic even when keys were pre-imported manually.
#   3. Once SSH host keys exist on this machine, derive its age recipient and
#      add it to .sops.yaml keys.age_devices, then rewrap encrypted files:
#        ssh-to-age < /etc/ssh/ssh_host_ed25519.pub
#        sops updatekeys src/secrets/ssh-personal.yml
#        sops updatekeys src/secrets/gpg-personal.yml
#        sops updatekeys src/secrets/git-identities.yml
#      After this step sops-nix uses this precedence chain:
#        machine SSH key -> primary GPG key -> primary SSH key.
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

  # Git identity is sourced from the managed decrypted payload so name/email/
  # signing key follow the same SOPS lifecycle as SSH/GPG material.
  gitIdentitySecretName = "git_identity_${primaryUsername}";

in
lib.mkIf isPrimaryUser {
  # Register the machine-identity decryption backend for the HM sops-nix module.
  # age: machine SSH key — works once keys.age_devices is populated in .sops.yaml.
  # Global backup recipients (primary_gpg / primary_ssh) are managed in .sops.yaml.
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

  # --------------------------------------------------------------------------
  # Git identity — SOPS-backed global name/email/signing key source-of-truth.
  # --------------------------------------------------------------------------
  sops.secrets."${gitIdentitySecretName}" = {
    sopsFile = ../secrets/git-identities.yml;
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
  # gitIdentityFromSops
  # Reads SOPS-managed git_identity_<user> and writes name/email/signingkey
  # into ~/.config/git/identity so identity stays in secret material rather
  # than hard-coded module attrsets.
  #
  # Why --file instead of --global:
  #   Home Manager owns ~/.config/git/config as a symlink into the read-only
  #   Nix store.  `git config --global` resolves to that path and fails with
  #   "Permission denied" when it tries to lock the file.  Writing to a
  #   separate include file avoids touching the HM-managed path entirely.
  #   git.nix wires `include.path = ~/.config/git/identity` so git reads
  #   the identity transparently.
  #
  # Algorithm:
  #   1. Read the decrypted SOPS payload (key=value lines).
  #   2. Validate all three required fields are non-empty.
  #   3. Write them into ~/.config/git/identity via `git config --file`.
  #      git config --file creates the file if absent and overwrites values
  #      idempotently on repeated activation runs.
  # --------------------------------------------------------------------------
  home.activation.gitIdentityFromSops = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    identity_path="${config.sops.secrets.${gitIdentitySecretName}.path}"

    if [ ! -f "$identity_path" ]; then
      echo "nucleus: missing decrypted Git identity secret at $identity_path." >&2
      exit 1
    fi

    identity_name="$(/usr/bin/grep -m1 '^name=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"
    identity_email="$(/usr/bin/grep -m1 '^email=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"
    identity_signing_key="$(/usr/bin/grep -m1 '^signingKey=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"

    if [ -z "$identity_name" ] || [ -z "$identity_email" ] || [ -z "$identity_signing_key" ]; then
      echo "nucleus: git identity payload must include name/email/signingKey entries." >&2
      exit 1
    fi

    # Write to the dedicated identity include file, not to the HM-managed config.
    identity_file="$HOME/.config/git/identity"
    mkdir -p "$(dirname "$identity_file")"
    ${pkgs.git}/bin/git config --file "$identity_file" user.name "$identity_name"
    ${pkgs.git}/bin/git config --file "$identity_file" user.email "$identity_email"
    ${pkgs.git}/bin/git config --file "$identity_file" user.signingkey "$identity_signing_key"
  '';

  # --------------------------------------------------------------------------
  # gpgImport
  # Imports the managed GPG private key from SOPS into the keyring and
  # enforces ultimate ownertrust on the managed primary fingerprint.
  #
  # Runs after sops-nix has materialized decrypted secret files.
  # gpg --import is idempotent, so repeated activations are safe.
  #
  # Trust invariant:
  #   Treat the first key carried by the managed secret blob as the user's
  #   primary key and always enforce ultimate ownertrust for that fingerprint.
  #   This keeps trust state deterministic even when the key material was
  #   manually imported before the first IaC-run import.
  #
  # Managed-key cleanup:
  #   We maintain a manifest at ~/.config/nucleus/managed-gpg-keys (one
  #   fingerprint per line) recording every primary fingerprint OUR activation
  #   has ever imported.  On each run:
  #     1. Compute current_fpr from the SOPS secret (dry-run, before import).
  #     2. For every fingerprint in the manifest that differs from current_fpr,
  #        delete that key from the keyring.  This removes keys that were
  #        managed by us but have since been rotated out of the SOPS secret.
  #     3. Import the current key.
  #     4. Write current_fpr to the manifest (before ownertrust, so the key is
  #        tracked even if ownertrust fails on the first bootstrap run, e.g.
  #        GnuPG 2.5 + Kyber IPC edge cases).
  #     5. Set ownertrust (warning-only; key is already imported and tracked).
  #   Keys never added to the manifest (user-imported manually) are never
  #   touched.  If the manifest is absent (first run or manually deleted) step
  #   2 is a no-op, which is always safe.  If current_fpr cannot be determined
  #   (dry-run failed), step 2 is also skipped to prevent accidental purge.
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

    # Extract the primary fingerprint from the managed secret without importing.
    # The `exit` in awk stops at the first fpr record, giving the primary key
    # fingerprint rather than a subkey fingerprint.
    first_key_fingerprint="$(${pkgs.gnupg}/bin/gpg --batch --import-options show-only --dry-run --with-colons --import "${config.sops.secrets.${gpgSecretName}.path}" 2>/dev/null | /usr/bin/awk -F: '$1 == "fpr" { print $10; exit }')"

    # Remove stale managed keys: those we imported previously (per manifest)
    # that are no longer the current managed key.  Guard on a non-empty
    # first_key_fingerprint so a dry-run parse failure never triggers deletion.
    nucleus_config_dir="$HOME/.config/nucleus"
    managed_keys_manifest="$nucleus_config_dir/managed-gpg-keys"
    if [ -n "$first_key_fingerprint" ] && [ -f "$managed_keys_manifest" ]; then
      while IFS= read -r stale_fpr; do
        [ -z "$stale_fpr" ] && continue
        if [ "$stale_fpr" != "$first_key_fingerprint" ]; then
          # Only delete if the key is actually present in the keyring.
          if ${pkgs.gnupg}/bin/gpg --batch --list-secret-keys "$stale_fpr" >/dev/null 2>&1; then
            if ! ${pkgs.gnupg}/bin/gpg --batch --yes --delete-secret-and-public-key "$stale_fpr"; then
              echo "nucleus: warning — failed to delete stale managed GPG key $stale_fpr from keyring." >&2
            else
              echo "nucleus: deleted stale managed GPG key $stale_fpr." >&2
            fi
          fi
        fi
      done < "$managed_keys_manifest"
    fi

    if ! ${pkgs.gnupg}/bin/gpg --import "${config.sops.secrets.${gpgSecretName}.path}"; then
      echo "nucleus: gpg import failed for ${gpgSecretName}." >&2
      exit 1
    fi

    if [ -z "$first_key_fingerprint" ]; then
      echo "nucleus: imported GPG keyring material but could not determine the managed primary fingerprint for ownertrust enforcement." >&2
      exit 1
    fi

    # Record the managed fingerprint immediately after a successful import so
    # this key is tracked for stale-cleanup even if the ownertrust step fails
    # (e.g., GnuPG 2.5 + Kyber IPC edge cases on first bootstrap).
    mkdir -p "$nucleus_config_dir"
    printf '%s\n' "$first_key_fingerprint" > "$managed_keys_manifest"

    if ! printf '%s:6:\n' "$first_key_fingerprint" | ${pkgs.gnupg}/bin/gpg --import-ownertrust; then
      echo "nucleus: warning — failed to enforce ultimate ownertrust for managed primary fingerprint $first_key_fingerprint; key is imported and tracked but trust state may require manual repair." >&2
    fi
  '';

  # --------------------------------------------------------------------------
  # sshKeyAdopt
  # Tracks the fingerprint of the managed personal SSH public key in
  # ~/.config/nucleus/managed-ssh-keys and flushes the in-memory SSH agent
  # when the fingerprint changes (i.e., the key was rotated in the SOPS secret).
  #
  # Why flush on rotation:
  #   ssh-agent caches private keys in memory by fingerprint.  After a SOPS
  #   rotation changes the key material on disk, any cached entry for the old
  #   fingerprint would be stale.  Flushing the entire agent ensures the new
  #   key is loaded via AddKeysToAgent=yes on the next outbound SSH connection.
  #
  # Device-specific key exclusion:
  #   /etc/ssh/ssh_host_ed25519_key is the bootstrap/backup decryption key
  #   for sops-nix and must never be tracked or cleaned up by this module.
  #   Only the personal user key (~/.ssh/ssh_personal_<user>.pub) is managed.
  #
  # Algorithm:
  #   1. Verify the managed public key has been materialized by sops-nix.
  #   2. Extract the SHA-256 fingerprint via ssh-keygen -lf.
  #   3. Read the previously recorded fingerprint from the manifest.
  #   4. If the fingerprint differs, flush the SSH agent (ssh-add -D).
  #   5. Write the current fingerprint to the manifest.
  # --------------------------------------------------------------------------
  home.activation.sshKeyAdopt = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    ssh_pub_path="${sshPublicKeyPath}"
    nucleus_config_dir="$HOME/.config/nucleus"
    managed_ssh_manifest="$nucleus_config_dir/managed-ssh-keys"

    if [ ! -f "$ssh_pub_path" ]; then
      # Not a hard error: sops-nix reports its own failure if materialization
      # did not complete.  Warn and skip so this activation does not mask the
      # upstream sops-nix error with a different message.
      echo "nucleus: managed SSH public key not found at $ssh_pub_path; skipping fingerprint adoption." >&2
    else
      new_fingerprint=""
      new_fingerprint="$(${pkgs.openssh}/bin/ssh-keygen -lf "$ssh_pub_path" 2>/dev/null | /usr/bin/awk '{print $2}')" || true

      if [ -z "$new_fingerprint" ]; then
        echo "nucleus: could not extract fingerprint from $ssh_pub_path; skipping adoption." >&2
      else
        old_fingerprint=""
        if [ -f "$managed_ssh_manifest" ]; then
          old_fingerprint="$(cat "$managed_ssh_manifest")" || old_fingerprint=""
        fi

        if [ -n "$old_fingerprint" ] && [ "$old_fingerprint" != "$new_fingerprint" ]; then
          # Flush in-memory SSH agent so stale cached key material is cleared.
          # AddKeysToAgent=yes in the SSH config re-loads the new key on the
          # next outbound SSH connection.
          echo "nucleus: managed SSH key fingerprint changed ($old_fingerprint -> $new_fingerprint); flushing SSH agent." >&2
          ${pkgs.openssh}/bin/ssh-add -D 2>/dev/null || true
        fi

        mkdir -p "$nucleus_config_dir"
        printf '%s\n' "$new_fingerprint" > "$managed_ssh_manifest"
      fi
    fi
  '';
}
