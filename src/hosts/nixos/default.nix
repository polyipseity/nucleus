# nixos/default.nix — NixOS entrypoint for the generic Linux host.
# Aggregates all host-specific module fragments; no settings live here directly.
{ ... }:
{
  # Host-scoped manual checklist consumed by shared Home Manager activation
  # modules. Keep this in the host entrypoint so shared modules never hardcode
  # paths under src/hosts/.
  nucleus.hostManualFile = ./MANUAL.md;

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
