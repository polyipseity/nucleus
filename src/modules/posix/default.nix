# POSIX system infrastructure modules.
{ ... }:
{
  imports = [
    ./base.nix
    ./gnupg.nix
    ./logging.nix
    ./user-shell.nix
  ];
}
