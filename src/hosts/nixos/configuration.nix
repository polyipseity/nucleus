{ ... }:
{
  imports = [
    ../../modules/core.nix
    ./base.nix
    ./hardware.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
    ./users.nix
  ];
}
