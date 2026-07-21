# Secret management via sops-nix.
# Primary-user pattern: uses SOPS-aware isPrimaryUser check
# (config.home.username == primaryUsername) so non-primary users never
# trigger secret decryption. Requires `username` in extraSpecialArgs.
{
  config,
  lib,
  pkgs,
  username ? null,
  ...
}:
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

  # Git identity is sourced from the managed decrypted payload so name/email/
  # signing key follow the same SOPS lifecycle as SSH/GPG material.
  gitIdentitySecretName = "git_identity_${primaryUsername}";

  # Per-user secrets file: src/secrets/users-<username>.yml.
  # May not exist until the user manually runs `sops edit src/secrets/users-<username>.yml`.
  # All downstream consumers guard on hasUserSecretFile / configPassEnabled so
  # activation succeeds even when the file has not been created yet.
  # WHY key name is unscoped: the file itself is already user-scoped
  # (src/secrets/users-<username>.yml), so repeating the username in every
  # key adds noise without improving isolation.
  rcloneConfigPassSecretName = "rclone_config_pass";
  rcloneConfigPassPath = "${config.home.homeDirectory}/.config/nucleus/secrets/rclone-config-pass";
  userSecretFilePath = ../secrets + "/users-${primaryUsername}.yml";
  hasUserSecretFile = builtins.pathExists userSecretFilePath;

  activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };
in
lib.mkIf isPrimaryUser {
  # Machine age key derived from /etc/ssh/ssh_host_ed25519_key by
  # deriveHostAgeKey in posix-sops.nix. keyFile avoids the permission issue
  # with sshKeyPaths (0600 root:wheel). gnupgHome is intentionally absent:
  # sops-nix rejects setting both keyFile and gnupgHome simultaneously.
  sops.age.keyFile = "/etc/sops/age/machine.txt";

  # Propagate rclone config passphrase availability to shell.nix and
  # cloud-drives.nix via nucleus.rclone options so those modules do not need
  # to re-check the filesystem themselves.
  nucleus.rclone.configPassEnabled = hasUserSecretFile;
  nucleus.rclone.configPassSecretPath = lib.mkIf hasUserSecretFile rcloneConfigPassPath;

  # --------------------------------------------------------------------------
  # rclone config passphrase (0400 — only owner needs read access)
  # --------------------------------------------------------------------------
  sops.secrets."${rcloneConfigPassSecretName}" = lib.mkIf hasUserSecretFile {
    sopsFile = userSecretFilePath;
    path = rcloneConfigPassPath;
    mode = "0400";
  };

  sops.secrets."${sshSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshPrivateKeyPath;
    mode = "0600";
  };

  # --------------------------------------------------------------------------
  # SSH public key
  # --------------------------------------------------------------------------
  sops.secrets."${sshPublicSecretName}" = {
    sopsFile = ../secrets/ssh-personal.yml;
    path = sshPublicKeyPath;
    mode = "0644";
  };

  # --------------------------------------------------------------------------
  # SSH RSA keypair (legacy fallback)
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
  # GPG key material
  # --------------------------------------------------------------------------
  sops.secrets."${gpgSecretName}" = {
    sopsFile = ../secrets/gpg-personal.yml;
    # No explicit path — let sops-nix manage it (typically /run/user/<uid>/…
    # on Linux, or ~/Library/… on macOS; both are outside persistent storage).
  };

  # --------------------------------------------------------------------------
  # Git identity
  # --------------------------------------------------------------------------
  sops.secrets."${gitIdentitySecretName}" = {
    sopsFile = ../secrets/git-identities.yml;
  };

  # --------------------------------------------------------------------------
  # System-wide secrets (AI API keys for LiteLLM proxy)
  # --------------------------------------------------------------------------
  sops.secrets."ai_openrouter_api_key" = {
    sopsFile = ../secrets/system.yml;
  };

  sops.secrets."ai_opencode_go_api_key" = {
    sopsFile = ../secrets/system.yml;
  };

  sops.secrets."ai_opencode_zen_api_key" = {
    sopsFile = ../secrets/system.yml;
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings =
      let
        baseSshSettings = {
          IdentityFile = sshIdentityFile;
          AddKeysToAgent = "yes";
          IgnoreUnknown = "UseKeychain";
        }
        // lib.optionalAttrs pkgs.stdenv.isDarwin { UseKeychain = "yes"; };
      in
      {
        "*" = baseSshSettings;
        "github.com" = baseSshSettings // {
          Hostname = "github.com";
        };
      };
  };

  # --------------------------------------------------------------------------
  # waitForSopsSecrets
  # Synchronises downstream activation on macOS where sops-nix registers a
  # LaunchAgent (org.nix-community.home.sops-nix) that runs
  # sops-install-secrets asynchronously.  launchctl bootstrap returns before
  # decryption completes, so without this barrier the hooks
  # git-identity, gpg-import, and ssh-key-adopt would fail with "missing
  # decrypted secret" on first apply or after a clean bootstrap.
  #
  # We poll the git identity secret as a sentinel: it is the smallest file
  # written by sops-install-secrets and serves as a reliable proxy for a
  # successful decryption run.  A 30-second deadline is intentionally generous
  # — sops-install-secrets completes in well under a second when
  # /etc/sops/age/machine.txt is present.
  #
  # On Linux, sops-nix runs sops-install-secrets inline (no LaunchAgent) so
  # the sentinel already exists when this hook fires; the loop exits
  # immediately with no added latency.
  # --------------------------------------------------------------------------
  home.activation.waitForSopsSecrets = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    "${activationBundle}/secrets/wait-for-sops-secrets.sh" "${
      config.sops.secrets.${gitIdentitySecretName}.path
    }"
  '';

  # --------------------------------------------------------------------------
  # git-identity
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
  home.activation."git-identity" = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
    "${activationBundle}/secrets/configure-git-identity.sh" "${
      config.sops.secrets.${gitIdentitySecretName}.path
    }" "${pkgs.git}/bin/git"
  '';

  # --------------------------------------------------------------------------
  # gpg-import
  # Imports the managed GPG private key from SOPS into the keyring and
  # enforces ultimate ownertrust on the managed primary fingerprint.
  #
  # Runs after waitForSopsSecrets has confirmed decrypted secret files are
  # present; gpg --import is idempotent, so repeated activations are safe.
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
  home.activation."gpg-import" = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
    "${activationBundle}/secrets/import-gpg-key.sh" \
      "${config.home.homeDirectory}/.gnupg" \
      "${pkgs.gnupg}/bin/gpg" \
      "${config.sops.secrets.${gpgSecretName}.path}"
  '';

  # --------------------------------------------------------------------------
  # ssh-key-adopt
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
  #   4. If the fingerprint differs (including when manifest is absent on first
  #      provision), flush the SSH agent (ssh-add -D).
  #   5. Write the current fingerprint to the manifest.
  # --------------------------------------------------------------------------
  home.activation."ssh-key-adopt" = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
    "${activationBundle}/secrets/adopt-ssh-key.sh" "${sshPublicKeyPath}" "${pkgs.openssh}/bin/ssh-keygen" "${pkgs.openssh}/bin/ssh-add"
  '';

  # --------------------------------------------------------------------------
  # verifySecretDecryption
  # Post-activation health check that verifies ALL SOPS files can be decrypted
  # by each registered backend after gpg-import and ssh-key-adopt have completed.
  #
  # Covers:
  #   - src/secrets/git-identities.yml
  #   - src/secrets/gpg-personal.yml
  #   - src/secrets/ssh-personal.yml
  #   - src/assets/wallpapers/*.sops  (enumerated dynamically via builtins.readDir)
  # All use the same .sops.yaml key groups (age_devices + primary_gpg).
  #
  # Five checks (in order):
  #   1. Materialization sanity: all sops-nix secret paths exist and are
  #      non-empty.  Guards against silent sops-nix failures.
  #   2. GPG key presence: managed primary fingerprint is in the keyring.
  #      Complements gpg-import — catches keyring state divergence.
  #   3. GPG SOPS recipient check: extract the fp: value from each SOPS file's
  #      plaintext sops.pgp[].fp metadata and verify that fingerprint is present
  #      in the secret keyring.  SOPS records the encryption subkey fingerprint
  #      (not the primary key fingerprint) in the fp: field; comparing the primary
  #      fingerprint directly produces false failures when SOPS chose a subkey.
  #      YAML SOPS files store fp as "    fp: HEX" (unquoted); binary SOPS files
  #      (e.g. wallpaper blobs) use JSON format with "\"fp\": \"HEX\""; both
  #      formats are handled by the extraction logic below.
  #      Combined with check 2 (primary key in keyring), this confirms we have the
  #      private key material to decrypt once the passphrase is provided.

  # --------------------------------------------------------------------------
  # verifySecretDecryption
  # Post-activation health check that verifies ALL SOPS files can be decrypted
  # by each registered backend after gpg-import and ssh-key-adopt have completed.
  #
  # Covers:
  #   - src/secrets/git-identities.yml
  #   - src/secrets/gpg-personal.yml
  #   - src/secrets/ssh-personal.yml
  #   - src/assets/wallpapers/*.sops  (enumerated dynamically via builtins.readDir)
  # All use the same .sops.yaml key groups (age_devices + primary_gpg).
  #
  # Five checks (in order):
  #   1. Materialization sanity: all sops-nix secret paths exist and are
  #      non-empty.  Guards against silent sops-nix failures.
  #   2. GPG key presence: managed primary fingerprint is in the keyring.
  #      Complements gpg-import — catches keyring state divergence.
  #   3. GPG SOPS recipient check: extract the fp: value from each SOPS file's
  #      plaintext sops.pgp[].fp metadata and verify that fingerprint is present
  #      in the secret keyring.  SOPS records the encryption subkey fingerprint
  #      (not the primary key fingerprint) in the fp: field; comparing the primary
  #      fingerprint directly produces false failures when SOPS chose a subkey.
  #      YAML SOPS files store fp as "    fp: HEX" (unquoted); binary SOPS files
  #      (e.g. wallpaper blobs) use JSON format with "\"fp\": \"HEX\""; both
  #      formats are handled by the extraction logic below.
  #      Combined with check 2 (primary key in keyring), this confirms we have the
  #      private key material to decrypt once the passphrase is provided.
  #      Accumulates failures, reports all failing files.
  #      Hard error — GPG is the last-resort global backup.
  #   4. Personal SSH age recipient check: derive the age public key from the
  #      managed personal SSH public key via ssh-to-age -i (passphrase-free
  #      public-key conversion), then search each SOPS file's plaintext
  #      sops.age[] metadata for the derived key value.  YAML SOPS files store
  #      the key as "recipient: age1..." (unquoted); binary SOPS files (e.g.
  #      wallpaper blobs) use JSON format "\"recipient\": \"age1...\"" (quoted).
  #      Searching for the bare age key value handles both formats.  No private
  #      key passphrase is required.  Accumulates failures, reports all failing
  #      files.  Hard error — the personal SSH key is the designated personal
  #      backup age recipient in .sops.yaml.
  #   5. Machine SSH host key existence: advisory warning if
  #      /etc/ssh/ssh_host_ed25519_key is absent.  Warning-only because on
  #      first bootstrap the host key may not yet be registered in .sops.yaml
  #      (step 3 of the bootstrap docs at the top of this file).
  #
  # Why JSON-tokenized while-read loop (checks 3 & 4):
  #   All SOPS file paths are baked into a JSON array at Nix evaluation
  #   time (builtins.toJSON), then injected at activation runtime via
  #   builtins.replaceStrings.  The external shell script iterates entries
  #   with a jq-powered while-read loop — eliminating concatMapStrings
  #   without sacrificing traceability: each iteration's command is still
  #   independently visible in the activation log via the displayName.
  #   Shell variables (_vsd_sops_gpg_fp, _vsd_ssh_age_pub) are expanded
  #   at activation runtime.
  # --------------------------------------------------------------------------
  home.activation.verifySecretDecryption =
    let
      wallpaperDir = ../assets/wallpapers;
      # Enumerate every *.sops blob in the wallpapers directory at eval time
      # so new wallpapers are automatically included in the health check.
      wallpaperSopsNames = lib.filter (n: lib.hasSuffix ".sops" n) (
        builtins.attrNames (builtins.readDir wallpaperDir)
      );
      # Build list of SOPS files with their paths and display names.
      # WHY regular paths instead of builtins.path: Avoid creating derivation
      # context warnings. The activation script will convert these to strings
      # naturally during shell code generation without requiring explicit
      # store-path construction.
      allSopsFiles = [
        {
          path = ../secrets/git-identities.yml;
          displayName = "git-identities.yml";
        }
        {
          path = ../secrets/gpg-personal.yml;
          displayName = "gpg-personal.yml";
        }
        {
          path = ../secrets/ssh-personal.yml;
          displayName = "ssh-personal.yml";
        }
      ]
      ++ map (n: {
        path = wallpaperDir + "/${n}";
        displayName = n;
      }) wallpaperSopsNames
      ++ lib.optional hasUserSecretFile {
        path = userSecretFilePath;
        displayName = "${primaryUsername}.yml";
      };
    in
    lib.hm.dag.entryAfter [ "git-identity" "gpg-import" "ssh-key-adopt" ] ''
      "${activationBundle}/secrets/verify-secret-decryption.sh" \
        "${pkgs.jq}/bin/jq" \
        "${pkgs.gnupg}/bin/gpg" \
        "${pkgs.ssh-to-age}/bin/ssh-to-age" \
        "${config.home.homeDirectory}/.gnupg" \
        '${builtins.toJSON allSopsFiles}' \
        "${config.sops.secrets.${gitIdentitySecretName}.path}" \
        "${config.sops.secrets.${sshSecretName}.path}" \
        "${config.sops.secrets.${sshPublicSecretName}.path}" \
        "${config.sops.secrets.${gpgSecretName}.path}" \
        "${config.home.homeDirectory}/.config/nucleus/managed-gpg-keys" \
        "${sshPublicKeyPath}"
    '';
}
