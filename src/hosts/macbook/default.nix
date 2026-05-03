{ username, ... }:
{
  imports = [ ../../modules/core.nix ];

  networking.hostName = "macbook";

  nix.settings.experimental-features = [ "flakes" "nix-command" ];

  sops = {
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
    gnupg.home = "/Users/${username}/.gnupg";
  };

  system.defaults = {
    NSGlobalDomain = {
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
    };
    dock = {
      autohide = true;
      tilesize = 36;
    };
  };

  system.stateVersion = 4;
}
