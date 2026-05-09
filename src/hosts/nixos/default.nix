# nixos/default.nix — NixOS entrypoint for the generic Linux host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  # Inject the host manual path into Home Manager at the user layer so the
  # system entrypoint never needs to define a Home Manager-only option.
  home-manager.sharedModules = [
    {
      nucleus.hostManualFile = ./MANUAL.md;
    }
  ];

  imports = [
    ../../modules/core.nix
    ../../modules/gnupg.nix
    ../../modules/posix-base.nix
    ../../modules/posix-security.nix
    ../../modules/posix-sops.nix
    ../../modules/posix-user-shell.nix
    ./ai.nix
    ./base.nix
    ./desktop.nix
    ./hardware/cpu.nix
    ./hardware/disks.nix
    ./hardware/gpu.nix
    ./networking.nix
    ./security.nix
    ./sops.nix
    ./users.nix
  ];
}
