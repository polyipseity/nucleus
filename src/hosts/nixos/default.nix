# nixos/default.nix — NixOS entrypoint for the generic Linux host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  imports = [
    ../../modules/core.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./base.nix
    ./hardware.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
    ./users.nix
  ];
}
