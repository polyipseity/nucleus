# POSIX system infrastructure modules.
{ ... }:
{
  imports = [
    ./agent-host-shell.nix
    ./base.nix
    ./gnupg.nix
    ./logging.nix
    ./sops.nix
    ./toolchain-links.nix
    ./user-shell.nix
  ];
}
