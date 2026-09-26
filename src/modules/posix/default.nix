# POSIX system infrastructure modules.
{ ... }:
{
  imports = [
    ./base.nix
    ./gnupg.nix
    ./logging.nix
    ./sops.nix
    ./user-shell.nix
  ];
}
