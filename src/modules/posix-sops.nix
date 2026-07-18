# modules/posix-sops.nix — Shared SOPS decryption key sources for POSIX hosts.
{
  pkgs,
  lib,
  username,
  ...
}:
let
  # ---------------------------------------------------------------------------
  # deriveHostAgeKey script text
  # Derives the age secret identity from the machine's SSH host key and writes
  # it to /etc/sops/age/machine.txt so the Home Manager sops-nix instance can
  # decrypt SOPS secrets without requiring root privileges.
  #
  # Why a dedicated derived file rather than sshKeyPaths in Home Manager:
  #   /etc/ssh/ssh_host_ed25519_key is owned root:wheel (macOS) or root:root
  #   (NixOS) with mode 0600.  The Home Manager sops-nix instance runs as the
  #   regular user; ssh-to-age must read the private key to derive the age
  #   identity and fails with "permission denied" in that context.  System
  #   activation runs as root and CAN read the host key, so we derive the age
  #   identity there and write it to a user-readable path:
  #   /etc/sops/age/machine.txt is owned by username (mode 0600) and is
  #   referenced via sops.age.keyFile in secrets.nix.
  #
  #   The system-level sops-nix instance (this module) keeps sshKeyPaths
  #   because system activation already runs as root.
  #
  # Idempotency:
  #   ssh-to-age is deterministic for a given SSH key; repeated runs always
  #   produce identical output.  We always overwrite to keep the file current
  #   if the host key is ever rotated.
  # ---------------------------------------------------------------------------
  deriveHostAgeKeyText =
    builtins.replaceStrings
      [ "__SSH_TO_AGE_BIN__" "__USERNAME__" ]
      [ "${pkgs.ssh-to-age}/bin/ssh-to-age" "${username}" ]
      (builtins.readFile ../scripts/lib/derive-host-age-key.sh);
in
{
  # ---------------------------------------------------------------------------
  # nix-darwin only allows hardcoded named scripts; deriveHostAgeKey must run
  # after openssh (which writes the host key), so use postActivation + mkBefore.
  # NixOS accepts any script name.
  # ---------------------------------------------------------------------------
  system.activationScripts =
    if pkgs.stdenv.isDarwin then
      { postActivation.text = lib.mkBefore deriveHostAgeKeyText; }
    else
      { deriveHostAgeKey.text = deriveHostAgeKeyText; };

  sops = {
    age = {
      # System activation runs as root and can read /etc/ssh/ssh_host_ed25519_key
      # directly; keep sshKeyPaths for the system-level sops-nix instance.
      # The Home Manager sops-nix instance (secrets.nix) references
      # /etc/sops/age/machine.txt (derived by deriveHostAgeKey above) via
      # sops.age.keyFile to avoid the user-permission issue at HM activation time.
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };

    # GnuPG fallback path differs by platform home directory convention.
    # sshKeyPaths must be explicitly emptied when gnupg.home is set per sops-nix
    # docs; the sops-nix default imports RSA SSH host keys via
    # defaultImportKeys "rsa", which causes the assertion
    #   "Exactly one of sops.gnupg.home and sops.gnupg.sshKeyPaths must be set"
    # on NixOS where services.openssh is enabled.  macOS avoids the conflict
    # because nix-darwin's OpenSSH setup often lacks RSA host-key definitions.
    gnupg = {
      home = if pkgs.stdenv.isDarwin then "/Users/${username}/.gnupg" else "/home/${username}/.gnupg";
      sshKeyPaths = [ ];
    };
  };
}
