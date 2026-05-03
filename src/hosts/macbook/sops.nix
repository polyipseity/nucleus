# macbook/sops.nix — SOPS decryption key sources for the MacBook host.
# Teaches sops-nix where to find the age recipient key (derived from the host
# SSH key) and the GnuPG home directory used as a fallback decryption path.
{ username, ... }:
{
  sops = {
    age = {
      # Derive the age recipient key from the host's ed25519 SSH host key.
      # This key is stable across rebuilds and does not require extra key management.
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    # GnuPG fallback: used when the host SSH key is unavailable (e.g. fresh
    # install before the first nix-darwin activation).
    gnupg.home = "/Users/${username}/.gnupg";
  };
}
