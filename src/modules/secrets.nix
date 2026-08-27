# Secret management via per-user SOPS files and activation-time materialization.
{
  config,
  lib,
  pkgs,
  repoRoot,
  ...
}:
let
  currentUsername = config.home.username;
  sshIdentityFile = "~/.ssh/ssh_personal_${currentUsername}";
  sshPrivateKeyPath = "${config.home.homeDirectory}/.ssh/ssh_personal_${currentUsername}";
  sshPublicKeyPath = "${sshPrivateKeyPath}.pub";
  nucleusUserRoot =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/nucleus"
    else
      "${config.home.homeDirectory}/.local/share/nucleus";
  rcloneConfigPassPath = "${nucleusUserRoot}/secrets/rclone-config-pass";
  gitIdentityPath = "${config.home.homeDirectory}/.config/git/identity";
  managedGpgKeysManifest = "${nucleusUserRoot}/managed-gpg-keys";
  managedSshKeyPathsManifest = "${nucleusUserRoot}/managed-ssh-key-paths";
  managedSshKeysManifest = "${nucleusUserRoot}/managed-ssh-keys";
  userSecretFilePath = ../secrets/users + "/${currentUsername}.yml";
  hasUserSecretFile = builtins.pathExists userSecretFilePath;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # Machine age key derived from /etc/ssh/ssh_host_ed25519_key by
  # deriveHostAgeKey in posix-sops.nix (root:nucleus-sops, mode 0640).
  # with sshKeyPaths (0600 root:wheel). gnupgHome is intentionally absent:
  # sops-nix rejects setting both keyFile and gnupgHome simultaneously.
  # sshKeyPaths must be empty: the host private key is root-only; HM reads
  # the derived identity from keyFile instead (same contract as posix-sops.nix).
  sops.age = {
    keyFile =
      if pkgs.stdenv.hostPlatform.isDarwin then
        "/Library/Application Support/nucleus/sops/age/machine.txt"
      else
        "/var/lib/nucleus/sops/age/machine.txt";
    sshKeyPaths = [ ];
  };

  # Propagate rclone config passphrase availability to shell.nix and
  # cloud-drives.nix via nucleus.rclone options so those modules do not need
  # to re-check the filesystem themselves.
  nucleus.rclone.configPassEnabled = hasUserSecretFile;
  nucleus.rclone.configPassSecretPath = lib.mkIf hasUserSecretFile rcloneConfigPassPath;

  programs.ssh = lib.mkIf hasUserSecretFile {
    enable = true;
    enableDefaultConfig = false;
    settings =
      let
        baseSshSettings = {
          IdentityFile = sshIdentityFile;
          AddKeysToAgent = "yes";
          IgnoreUnknown = "UseKeychain";
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin { UseKeychain = "yes"; };
      in
      {
        "*" = baseSshSettings;
        "github.com" = baseSshSettings // {
          Hostname = "github.com";
        };
      };
  };

  # --------------------------------------------------------------------------
  # materialize-user-secrets
  # Decrypts src/secrets/users/<username>.yml and writes GPG, SSH, Git, and
  # rclone material directly via decrypt-sops.sh instead of sops-nix secret
  # paths for per-user payloads.
  # --------------------------------------------------------------------------
  home.activation.materialize-user-secrets = lib.mkIf hasUserSecretFile (
    lib.hm.dag.entryAfter [ "sops-nix" ] ''
      "${activationBundle}/src/scripts/secrets/materialize-user-secrets.sh" \
        "${repoRoot}" \
        "${currentUsername}" \
        "${pkgs.gnupg}/bin/gpg" \
        "${pkgs.git}/bin/git" \
        "${pkgs.openssh}/bin/ssh-keygen" \
        "${pkgs.openssh}/bin/ssh-add" \
        "${pkgs.sops}/bin/sops" \
        "/etc/ssh/ssh_host_ed25519_key" \
        "${
          if pkgs.stdenv.hostPlatform.isDarwin then
            "/Library/Application Support/nucleus/sops/age/machine.txt"
          else
            "/var/lib/nucleus/sops/age/machine.txt"
        }" \
        "${pkgs.gawk}/bin/awk"
    ''
  );

  # --------------------------------------------------------------------------
  # verify-secret-decryption
  # Post-activation health check that verifies ALL SOPS files can be decrypted
  # by each registered backend after materialize-user-secrets has completed.
  #
  # Covers:
  #   - src/secrets/users/<username>.yml (when present)
  #   - src/users/<username>/wallpapers/encrypted/*.sops  (overlay merge with default)
  # All use the same .sops.yaml key groups (age_devices + primary_gpg).
  #
  # Five checks (in order):
  #   1. Materialization sanity: managed SSH keys, Git identity, and manifest
  #      files exist and are non-empty.
  #   2. GPG key presence: every fingerprint in managed-gpg-keys is in the
  #      keyring.
  #   3. GPG SOPS recipient check for all SOPS files.
  #   4. Personal SSH age recipient check for all SOPS files.
  #   5. Machine SSH host key existence (warning-only).
  # --------------------------------------------------------------------------
  home.activation.verify-secret-decryption =
    let
      overlayLib = import ./lib/users-overlay.nix;
      wallpaperPaths = import ./lib/wallpaper-paths.nix {
        inherit lib;
        repoRoot = ../../.;
        overlayLib = overlayLib;
      };
      usersRoot = ../../. + "/src/users";
      managedUserNames = lib.filter (name: name != "default") (
        builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir usersRoot))
      );
      wallpaperSopsFiles = lib.flatten (
        map (
          userName:
          map (blobName: {
            path = wallpaperPaths.encryptedBlobPath userName blobName;
            displayName = "${userName}/${blobName}";
          }) (wallpaperPaths.listEncryptedWallpaperBlobs userName)
        ) managedUserNames
      );
      allSopsFiles =
        lib.optional hasUserSecretFile {
          path = userSecretFilePath;
          displayName = "${currentUsername}.yml";
        }
        ++ wallpaperSopsFiles;
    in
    lib.mkIf hasUserSecretFile (
      lib.hm.dag.entryAfter [ "materialize-user-secrets" ] ''
        "${activationBundle}/src/scripts/secrets/verify-secret-decryption.sh" \
          "${pkgs.jq}/bin/jq" \
          "${pkgs.gnupg}/bin/gpg" \
          "${pkgs.ssh-to-age}/bin/ssh-to-age" \
          "${config.home.homeDirectory}/.gnupg" \
          '${builtins.toJSON allSopsFiles}' \
          "${gitIdentityPath}" \
          "${sshPrivateKeyPath}" \
          "${sshPublicKeyPath}" \
          "${managedGpgKeysManifest}" \
          "${managedSshKeyPathsManifest}" \
          "${managedSshKeysManifest}"
      ''
    );
}
