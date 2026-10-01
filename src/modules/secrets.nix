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

  # Spelled once for sops.age.keyFile and the derive-host-age-key.sh
  # invocation; the shell readers resolve it through nucleus_machine_age_key_path.
  machineAgeKeyPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/Library/Application Support/nucleus/sops/age/machine.txt"
    else
      "/var/lib/nucleus/sops/age/machine.txt";

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # Derived from /etc/ssh/ssh_host_ed25519_key by
  # src/scripts/secrets/derive-host-age-key.sh under the nucleus SYSTEM root.
  # gnupgHome is absent because sops-nix rejects setting both it and keyFile;
  # sshKeyPaths is empty because the host private key is root-only and HM reads
  # the derived identity from keyFile.
  sops.age = {
    keyFile = machineAgeKeyPath;
    sshKeyPaths = [ ];
  };

  # Lets shell.nix and cloud-drives.nix skip their own filesystem check.
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

  # Decrypts src/secrets/users/<username>.yml through decrypt-sops.sh, which
  # writes the per-user payloads where sops-nix secret paths cannot.
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
        "${machineAgeKeyPath}" \
        "${pkgs.gawk}/bin/awk"
    ''
  );

  # Checks every registered SOPS file against every backend, after
  # materialize-user-secrets: materialization sanity (a passphrase-protected
  # SSH key is valid; see verify-secret-decryption.sh for what the probe
  # cannot prove), GPG key presence, GPG SOPS recipients, personal SSH age
  # recipients, then the machine host key (warning-only).
  home.activation.verify-secret-decryption =
    let
      overlayLib = import ./lib/users-overlay.nix { inherit lib; };
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
          "${pkgs.openssh}/bin/ssh-keygen" \
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
