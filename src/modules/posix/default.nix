# POSIX system infrastructure modules.
{ ... }:
{
  imports = [
    ./gnupg.nix
    ./logging.nix
  ];
}
