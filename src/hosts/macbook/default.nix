{ ... }:
{
  imports = [ ../../modules/core.nix ];

  networking.hostName = "macbook";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

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
