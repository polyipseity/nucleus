{ ... }:
{
  imports = [
    ../../modules/core.nix
    ./activation.nix
    ./base.nix
    ./defaults.nix
    ./homebrew.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
  ];
}
