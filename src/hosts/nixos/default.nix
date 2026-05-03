# nixos/default.nix — NixOS entrypoint for the generic Linux host.
# Aggregates all host-specific module fragments; no settings live here directly.
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
