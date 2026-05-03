{ username, ... }:
{
  sops = {
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    gnupg.home = "/Users/${username}/.gnupg";
  };
}
