# nixos/sops.nix — SOPS decryption key sources for the NixOS host.
# Teaches sops-nix where to find the age recipient key (derived from the host
# SSH key) and the GnuPG home directory used as a fallback decryption path.
{ username, ... }:
{
  sops = {
    age = {
      # Derive the age recipient key from the host's ed25519 SSH host key.
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    # GnuPG fallback: used when the host SSH key is unavailable.
    gnupg.home = "/home/${username}/.gnupg";
  };
}
