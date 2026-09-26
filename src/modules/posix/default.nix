# POSIX system infrastructure modules.
{ ... }:
{
  imports = [
    ./agent-host-shell.nix
    ./base.nix
    ./gnupg.nix
    ./logging.nix
    ./sops.nix
    ./user-shell.nix
  ];
}
