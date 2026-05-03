# modules/posix-sops.nix — Shared SOPS decryption key sources for POSIX hosts.
{ pkgs, username, ... }:
{
  sops = {
    age = {
      # Derive the age recipient key from the host's ed25519 SSH host key.
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };

    # GnuPG fallback path differs by platform home directory convention.
    gnupg.home =
      if pkgs.stdenv.isDarwin then
        "/Users/${username}/.gnupg"
      else
        "/home/${username}/.gnupg";
  };
}
