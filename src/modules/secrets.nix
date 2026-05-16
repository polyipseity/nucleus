# modules/secrets.nix — Secret management for Home Manager.
#
# All decryption is delegated to sops-nix (sops.secrets). Imperative activation
# hooks handle side-effects that have no declarative equivalent:
#   - gpgImport:              imports the managed GPG key and enforces ownertrust
#   - gitIdentityFromSops:    writes git name/email/signingkey from SOPS payload
#   - sshKeyAdopt:            tracks the SSH key fingerprint; flushes agent on rotation
#   - verifySecretDecryption: post-activation health check for each decryption backend
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
#   1. Import your GPG private key so sops updatekeys can re-encrypt secrets
#      for the new machine age recipient:
#        gpg --import <backup-key-file>
#   2. Run: ./scripts/bootstrap.sh apply   (or darwin-rebuild / nixos-rebuild)
#      apply.sh calls register_host_age_key_if_needed which automatically:
#        a. Derives the machine age public key from /etc/ssh/ssh_host_ed25519_key.pub.
#        b. Inserts it into .sops.yaml before the machine-keys-end marker comment.
#        c. Rewraps every encrypted file so this machine can decrypt them.
#      The system activation script deriveHostAgeKey (posix-sops.nix) then writes
#      the machine age private key to /etc/sops/age/machine.txt.  HM sops-nix
#      uses this file to decrypt all SOPS secrets without a pre-imported GPG key.
#      The gpgImport activation (below) imports the managed GPG key automatically
#      from the decrypted SOPS payload.
#      After apply completes, commit the updated .sops.yaml and rewrapped secrets:
#        git add .sops.yaml src/secrets src/assets/wallpapers
#        git commit -m "chore: register <hostname> machine age key"
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
  sshExtraOptions = {
    AddKeysToAgent = "yes";
    # Non-Apple OpenSSH (for example nixpkgs openssh) rejects UseKeychain.
    # IgnoreUnknown keeps one shared ~/.ssh/config usable across clients.
    IgnoreUnknown = "UseKeychain";
  }
  // lib.optionalAttrs pkgs.stdenv.isDarwin {
    UseKeychain = "yes";
  };

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

in
lib.mkIf isPrimaryUser {
  # Register the machine-identity decryption backend for the HM sops-nix module.
  # /etc/sops/age/machine.txt is derived by the system activation script
  # deriveHostAgeKey in posix-sops.nix from /etc/ssh/ssh_host_ed25519_key.
  # Using keyFile instead of sshKeyPaths avoids the permission issue on macOS
  # and NixOS where /etc/ssh/ssh_host_ed25519_key is 0600 root:wheel/root:root
  # and the Home Manager sops-nix instance runs as the regular user.
  # sops.gnupg.home is intentionally absent: sops-nix rejects keyFile and
  # gnupgHome being set simultaneously (manifest validation error).  The machine
  # age key registered in .sops.yaml age_devices is sufficient for all secret
  # decryption at HM activation time; GPG is populated by gpgImport (below)
  # from the decrypted SOPS payload and remains available for signing thereafter.
  sops.age.keyFile = "/etc/sops/age/machine.txt";

  # --------------------------------------------------------------------------
  # SSH private key — sops-nix owns decryption, file write, and chmod 600.
  # --------------------------------------------------------------------------

  # Propagate rclone config passphrase availability to shell.nix and
  # cloud-drives.nix via nucleus.rclone options so those modules do not need
  # to re-check the filesystem themselves.
  nucleus.rclone.configPassEnabled = hasUserSecretFile;
  nucleus.rclone.configPassSecretPath = lib.mkIf hasUserSecretFile rcloneConfigPassPath;

  # --------------------------------------------------------------------------
  # Per-user secret: rclone config passphrase.
  # Encrypts the entire rclone.conf so stored cloud credentials are protected.
  # WHY 0400: only the owner needs read access; rclone never modifies this file.
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
  # waitForSopsSecrets
  # Synchronises downstream activation on macOS where sops-nix registers a
  # LaunchAgent (org.nix-community.home.sops-nix) that runs
  # sops-install-secrets asynchronously.  launchctl bootstrap returns before
  # decryption completes, so without this barrier the hooks
  # gitIdentityFromSops, gpgImport, and sshKeyAdopt would fail with "missing
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
    _wss_sentinel="${config.sops.secrets.${gitIdentitySecretName}.path}"
    _wss_deadline=30
    _wss_waited=0
    while [ ! -s "$_wss_sentinel" ] && [ "$_wss_waited" -lt "$_wss_deadline" ]; do
      sleep 1
      _wss_waited=$((_wss_waited + 1))
    done
    if [ ! -s "$_wss_sentinel" ]; then
      echo "waitForSopsSecrets: timed out after 30 s waiting for sops-nix to materialize secrets; sops-install-secrets may have failed or /etc/sops/age/machine.txt may be absent." >&2
      exit 1
    fi
  '';

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
  home.activation.gitIdentityFromSops = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
    identity_path="${config.sops.secrets.${gitIdentitySecretName}.path}"

    if [ ! -f "$identity_path" ]; then
      echo "gitIdentityFromSops: missing decrypted Git identity secret at $identity_path." >&2
      exit 1
    fi

    identity_name="$(/usr/bin/grep -m1 '^name=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"
    identity_email="$(/usr/bin/grep -m1 '^email=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"
    identity_signing_key="$(/usr/bin/grep -m1 '^signingKey=' "$identity_path" | /usr/bin/cut -d '=' -f 2-)"

    if [ -z "$identity_name" ] || [ -z "$identity_email" ] || [ -z "$identity_signing_key" ]; then
      echo "gitIdentityFromSops: git identity payload must include name/email/signingKey entries." >&2
      exit 1
    fi

    # Write to the dedicated identity include file, not to the HM-managed config.
    identity_file="$HOME/.config/git/identity"
    mkdir -p "$(dirname "$identity_file")"
    ${pkgs.git}/bin/git config --file "$identity_file" user.name "$identity_name"
    ${pkgs.git}/bin/git config --file "$identity_file" user.email "$identity_email"
    ${pkgs.git}/bin/git config --file "$identity_file" user.signingkey "$identity_signing_key"
    # Restrict the identity include file to owner-read-only: it contains the
    # GPG signing key reference, which minimises visibility to other local users.
    chmod 600 "$identity_file"
  '';

  # --------------------------------------------------------------------------
  # gpgImport
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
  home.activation.gpgImport = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
    export GNUPGHOME="${config.home.homeDirectory}/.gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"

    if [ ! -f "${config.sops.secrets.${gpgSecretName}.path}" ]; then
      echo "gpgImport: missing decrypted GPG secret at ${
        config.sops.secrets.${gpgSecretName}.path
      }; cannot import key material." >&2
      exit 1
    fi

    # Extract the primary fingerprint from the managed secret without importing.
    # The `exit` in awk stops at the first fpr record, giving the primary key
    # fingerprint rather than a subkey fingerprint.
    # The || true prevents a silent set -e / pipefail exit if gpg emits errors;
    # the [ -z ] guard below catches and reports an empty result explicitly.
    first_key_fingerprint="$(${pkgs.gnupg}/bin/gpg --batch --import-options show-only --dry-run --with-colons --import "${
      config.sops.secrets.${gpgSecretName}.path
    }" | /usr/bin/awk -F: '$1 == "fpr" { print $10; exit }')" || true

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
              echo "gpgImport: warning — failed to delete stale managed GPG key $stale_fpr from keyring." >&2
            else
              echo "gpgImport: deleted stale managed GPG key $stale_fpr." >&2
            fi
          fi
        fi
      done < "$managed_keys_manifest"
    fi

    if ! ${pkgs.gnupg}/bin/gpg --import "${config.sops.secrets.${gpgSecretName}.path}"; then
      echo "secrets: gpg import failed for ${gpgSecretName}." >&2
      exit 1
    fi

    if [ -z "$first_key_fingerprint" ]; then
      echo "secrets: imported GPG keyring material but could not determine the managed primary fingerprint for ownertrust enforcement." >&2
      exit 1
    fi

    # Record the managed fingerprint immediately after a successful import so
    # this key is tracked for stale-cleanup even if the ownertrust step fails
    # (e.g., GnuPG 2.5 + Kyber IPC edge cases on first bootstrap).
    mkdir -p "$nucleus_config_dir"
    printf '%s\n' "$first_key_fingerprint" > "$managed_keys_manifest"
    # Restrict manifest to owner-read-only: the fingerprint identifies the
    # managed key; excess visibility could aid key targeting.
    chmod 600 "$managed_keys_manifest"

    if ! printf '%s:6:\n' "$first_key_fingerprint" | ${pkgs.gnupg}/bin/gpg --import-ownertrust; then
      echo "secrets: warning — failed to enforce ultimate ownertrust for managed primary fingerprint $first_key_fingerprint; key is imported and tracked but trust state may require manual repair." >&2
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
  #   4. If the fingerprint differs (including when manifest is absent on first
  #      provision), flush the SSH agent (ssh-add -D).
  #   5. Write the current fingerprint to the manifest.
  # --------------------------------------------------------------------------
  home.activation.sshKeyAdopt = lib.hm.dag.entryAfter [ "waitForSopsSecrets" ] ''
     ssh_pub_path="${sshPublicKeyPath}"
     nucleus_config_dir="$HOME/.config/nucleus"
     managed_ssh_manifest="$nucleus_config_dir/managed-ssh-keys"

     if [ ! -f "$ssh_pub_path" ]; then
       # Not a hard error: sops-nix reports its own failure if materialization
       # did not complete.  Warn and skip so this activation does not mask the
       # upstream sops-nix error with a different message.
       echo "secrets: managed SSH public key not found at $ssh_pub_path; skipping fingerprint adoption." >&2
     else
       new_fingerprint=""
       new_fingerprint="$(${pkgs.openssh}/bin/ssh-keygen -lf "$ssh_pub_path" | /usr/bin/awk '{print $2}')" || true

       if [ -z "$new_fingerprint" ]; then
         echo "secrets: could not extract fingerprint from $ssh_pub_path; skipping adoption." >&2
       else
         old_fingerprint=""
         if [ -f "$managed_ssh_manifest" ]; then
           old_fingerprint="$(cat "$managed_ssh_manifest")" || old_fingerprint=""
         fi

         if [ "$old_fingerprint" != "$new_fingerprint" ]; then
           # Flush in-memory SSH agent so stale cached key material is cleared.
           # The guard intentionally omits the `[ -n "$old_fingerprint" ]` check
           # so that on first provision (absent manifest, empty old_fingerprint)
           # any pre-placed key already loaded in the agent is also evicted.
           # AddKeysToAgent=yes in the SSH config re-loads the new key on the
           # next outbound SSH connection.
            echo "secrets: managed SSH key fingerprint changed ($old_fingerprint -> $new_fingerprint); flushing SSH agent." >&2
            # 2>/dev/null is intentional: ssh-add -D outputs "Could not open a
            # connection to your authentication agent" when no agent is running.
            # That failure is benign here — nothing to flush — and the noise
            # would obscure the genuinely meaningful activation output above.
            ${pkgs.openssh}/bin/ssh-add -D 2>/dev/null || true
         fi

        mkdir -p "$nucleus_config_dir"
        printf '%s\n' "$new_fingerprint" > "$managed_ssh_manifest"
        # Restrict manifest to owner-read-only: SSH fingerprint data can be
        # used to correlate keys across systems; minimise unnecessary visibility.
        chmod 600 "$managed_ssh_manifest"
      fi
    fi
  '';

  # --------------------------------------------------------------------------
  # verifySecretDecryption
  # Post-activation health check that verifies ALL SOPS files can be decrypted
  # by each registered backend after gpgImport and sshKeyAdopt have completed.
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
  #      Complements gpgImport — catches keyring state divergence.
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
  # Why lib.concatMapStrings for checks 3 & 4:
  #   Generating static inline shell commands at Nix evaluation time avoids
  #   shell loops/arrays and keeps each invocation independently visible in
  #   the activation trace.  The Nix store paths for each SOPS file are
  #   baked in at eval time; shell variables such as _vsd_sops_gpg_fp and
  #   _vsd_ssh_age_pub are expanded at activation runtime.
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
    lib.hm.dag.entryAfter [ "gitIdentityFromSops" "gpgImport" "sshKeyAdopt" ] ''
      # --- 1. Materialization sanity check ---
      for _vsd_path in \
          "${config.sops.secrets.${sshSecretName}.path}" \
          "${config.sops.secrets.${sshPublicSecretName}.path}" \
          "${config.sops.secrets.${gpgSecretName}.path}" \
          "${config.sops.secrets.${gitIdentitySecretName}.path}"; do
        if [ ! -s "$_vsd_path" ]; then
          echo "secrets: ERROR — decrypted secret missing or empty at '$_vsd_path'." >&2
          exit 1
        fi
      done

      # --- 2. GPG key presence in keyring ---
      _vsd_gpg_manifest="$HOME/.config/nucleus/managed-gpg-keys"
      if [ ! -s "$_vsd_gpg_manifest" ]; then
        echo "secrets: ERROR — managed-gpg-keys manifest missing or empty; gpgImport may have failed." >&2
        exit 1
      fi
      _vsd_managed_fpr="$(head -n1 "$_vsd_gpg_manifest")"
      # Dump all secret-key fingerprints once and cache the colon-format output;
      # reused by check 3 to avoid repeated invocations.  --with-colons forces
      # machine-readable non-interactive output; --no-autostart prevents GPG from
      # launching a new agent daemon (which deadlocks on macOS when the agent
      # socket directory is not yet ready during non-interactive activation).
      _vsd_gpg_all_secret_fprs="$(GNUPGHOME="${config.home.homeDirectory}/.gnupg" \
        ${pkgs.gnupg}/bin/gpg --with-colons --no-autostart --list-secret-keys)" || true
      if ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_managed_fpr"; then
        echo "secrets: ERROR — managed GPG key $_vsd_managed_fpr not in keyring after gpgImport." >&2
        exit 1
      fi

      # --- 3. GPG SOPS recipient check for all SOPS files ---
      # Rather than live-decrypting with GPG (which requires the private key
      # passphrase and fails non-interactively), extract the fp: value from each
      # SOPS file's plaintext sops.pgp[].fp metadata (always unencrypted) and
      # verify that fingerprint is present in our secret keyring.  SOPS records
      # the encryption SUBKEY fingerprint in the fp: field, not the primary key
      # fingerprint, so comparing the primary fingerprint directly produces false
      # failures when SOPS chose a subkey (e.g., a Kyber encryption subkey).
      # Combined with check 2 (primary key in keyring), this confirms we have the
      # private key material to decrypt once the passphrase is provided.
      # YAML SOPS files store fp as "    fp: HEX" (unquoted); binary SOPS files
      # (e.g. wallpaper blobs) use JSON format with "\"fp\": \"HEX\"".  The
      # extraction below handles both formats.
      _vsd_gpg_failures=""
      ${lib.concatMapStrings (
        { path, displayName }:
        ''
          # Binary SOPS files use JSON format ("fp": "HEX") while YAML SOPS files
          # use "    fp: HEX".  The combined -E pattern matches both; the second
          # grep -oE extracts the hex fingerprint directly, avoiding the need for
          # tr-based quote stripping.  The || true prevents a silent set -e exit
          # when grep finds no match, allowing the [ -z ] check below to report
          # the failure cleanly instead of silently aborting the activation chain.
          _vsd_sops_gpg_fp="$(/usr/bin/grep -m1 -E '[[:space:]]fp: |"fp": ' "${path}" | /usr/bin/grep -oE '[0-9A-Fa-f]{40,}')" || true
          if [ -z "$_vsd_sops_gpg_fp" ] || \
              ! printf '%s\n' "$_vsd_gpg_all_secret_fprs" | /usr/bin/grep -qF "$_vsd_sops_gpg_fp"; then
            _vsd_gpg_failures="$_vsd_gpg_failures ${displayName}"
          fi
        ''
      ) allSopsFiles}
      if [ -n "$_vsd_gpg_failures" ]; then
        echo "secrets: ERROR — GPG SOPS decryption check failed for:$_vsd_gpg_failures; managed GPG key may not be registered in .sops.yaml." >&2
        exit 1
      fi

      # --- 4. Personal SSH age recipient check for all SOPS files ---
      # Rather than live-decrypting with the SSH private key (which requires the
      # key passphrase and fails non-interactively), derive the age public key
      # from the managed personal SSH public key via ssh-to-age -i (passphrase-
      # free public-key conversion) and verify it appears in each SOPS file's
      # plaintext sops.age[] metadata.  YAML SOPS files store the key as
      # "recipient: age1..." (unquoted); binary SOPS files (e.g. wallpaper blobs)
      # use JSON format "\"recipient\": \"age1...\"" (quoted key and value).
      # Searching for the bare age key value with grep -qF handles both formats.
      # No private key material is accessed.
      _vsd_ssh_age_pub=""
      _vsd_ssh_failures=""
      _vsd_ssh_age_pub="$(${pkgs.ssh-to-age}/bin/ssh-to-age -i "${sshPublicKeyPath}")" || true
      if [ -z "$_vsd_ssh_age_pub" ]; then
        echo "secrets: ERROR — personal SSH key age-backend SOPS decryption check failed for: <ssh-to-age pubkey derivation failed>; ensure ${sshPublicKeyPath} is a valid Ed25519 public key." >&2
        exit 1
      fi
      ${lib.concatMapStrings (
        { path, displayName }:
        ''
          # Search for the bare age key value rather than the full "recipient: KEY"
          # string: YAML SOPS stores "recipient: KEY" (unquoted) while binary SOPS
          # uses JSON "\"recipient\": \"KEY\"" (quoted key and value).  The age key
          # is a unique 59+ character bech32 string that identifies the recipient
          # unambiguously without the surrounding field label.
          /usr/bin/grep -qF "$_vsd_ssh_age_pub" "${path}" \
            || _vsd_ssh_failures="$_vsd_ssh_failures ${displayName}"
        ''
      ) allSopsFiles}
      if [ -n "$_vsd_ssh_failures" ]; then
        echo "secrets: ERROR — personal SSH key age-backend SOPS decryption check failed for:$_vsd_ssh_failures; SSH key may not be registered in .sops.yaml as an age recipient." >&2
        exit 1
      fi

      # --- 5. Machine age key existence check (warning-only) ---
      # Warning-only: on first bootstrap the host SSH key may not yet be registered
      # in .sops.yaml as a device age recipient, so the derived key file may be
      # absent.  Once deriveHostAgeKey (posix-sops.nix) has run and the machine
      # age recipient is in .sops.yaml, this check will pass silently on every
      # subsequent apply.
      if [ ! -f "/etc/sops/age/machine.txt" ]; then
        echo "secrets: warning — /etc/sops/age/machine.txt missing; this machine cannot be a SOPS age device recipient until the host key is registered in .sops.yaml and deriveHostAgeKey has run successfully." >&2
      fi
    '';
}
