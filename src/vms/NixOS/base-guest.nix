# src/vms/NixOS/base-guest.nix - Shared NixOS guest configuration for
# nixos-generators type builds, built once per NixOS VM type into the read-only
# system image.  Carries NO per-VM identity (no hostname, credentials, or SSH
# keys): per-VM identity lives in src/vms/guests/<id>/guest.nix, which imports
# this file and overrides the generic placeholder user via _module.args, and
# applies to the per-VM data disk at setup time (see vm_inject_guest).
# scripts/vm.sh builds the image on macOS and NixOS hosts:
#
#   nix run github:nix-community/nixos-generators -- \
#     --format-path ./src/vms/NixOS/formats/qcow-btrfs.nix \
#     --system x86_64-linux \
#     --configuration ./src/vms/NixOS/base-guest.nix \
#     -o <output-dir>
#
# qcow-efi-btrfs on aarch64 hosts, aarch64-linux on Apple Silicon.  On Windows,
# src/platforms/Windows/modules/system/Invoke-VMSetup.ps1 uses
# src/vms/NixOS/packer.pkr.hcl, which generates a similar configuration inline
# during a Packer QEMU build.
#
# Do NOT declare fileSystems, boot.loader, or hardware-configuration here: the
# nixos-generators format modules inject the right disk and bootloader setup for
# qcow-btrfs (BIOS/hybrid) and qcow-efi-btrfs (UEFI with a Btrfs root).
# Excluded: src/hosts/NixOS/ai.nix (no AI models inside VMs), vms.nix (no nested
# VM support needed), hardware/* (qemu-guest.nix covers virtualized hardware),
# jellyfin.nix (a singleton media server is not guest-appropriate), and
# src/modules/env/env-secrets-sops.nix (its sops.secrets need the sops-nix module,
# which nixos-generators does not load; the guest takes credentials from
# NUCLEUS_VM_GUEST_* environment variables instead).
#
# Source: https://github.com/nix-community/nixos-generators
{
  modulesPath,
  lib,
  pkgs,
  username,
  ...
}:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    # WHY: relative to src/vms/NixOS/, repo files are three levels up (../../../src).
    # Shared POSIX modules from src/modules/posix/
    ../../../src/modules/core.nix
    ../../../src/modules/posix/gnupg.nix
    ../../../src/modules/posix/base.nix
    ../../../src/modules/posix/security.nix
    ../../../src/modules/posix/user-shell.nix
    # NixOS host modules (excluding vms, hardware, ai, jellyfin infrastructure)
    ../../../src/hosts/NixOS/base.nix
    ../../../src/hosts/NixOS/desktop.nix
    ../../../src/hosts/NixOS/networking.nix
    ../../../src/hosts/NixOS/security.nix
    ../../../src/hosts/NixOS/users.nix
  ];

  # WHY: nixos-generators passes no specialArgs, so thread generic placeholders
  # for the two module args the real hosts supply: posix/base.nix picks its
  # per-host gitconfig by hostName, and the shared user modules key off username.
  # This is the TYPE build, so the per-VM delta src/vms/guests/<id>/guest.nix
  # overrides both with the real values from NUCLEUS_VM_GUEST_*.
  _module.args = {
    # WHY: posix/base.nix and other shared modules now take `repoRoot` as a
    # module arg (threaded via specialArgs on the real hosts). nixos-generators
    # passes no specialArgs, so inject the repo root here. The guest image is
    # built from the repo tree, so the repo root is the parent of src/.
    repoRoot = ../..;
    hostName = lib.mkDefault "nixos";
    username = lib.mkDefault "nixos";
  };

  # VirtioFS is configured after first boot, once the host actually exposes a
  # shared directory.  Forcing virtio_fs into the initrd breaks image generation
  # before the VM boots, because current aarch64 guest kernels may not ship it as
  # a standalone module.

  services.qemuGuest.enable = true;
  services.openssh.enable = true;

  # WHY: hosts/NixOS/security.nix enables the standalone programs.ssh agent and
  # GNOME's default-on gcr-ssh-agent asserts against it, so drop gcr's.
  services.gnome.gcr-ssh-agent.enable = lib.mkForce false;

  # WHY: Steam and its 32-bit Mesa/Vulkan drivers are x86_64-only, so the aarch64
  # guest forces both off (nixpkgs asserts enable32Bit cannot be set there) and
  # keeps the rest of the desktop parity.
  hardware.graphics.enable32Bit = lib.mkForce false;
  programs.steam.enable = lib.mkForce false;

  # WHY: desktop.nix installs parsec-bin and the real host allows unfree packages
  # through mkPkgs' config.allowUnfree, which a standalone nixos-generators
  # evaluation does not set, so mirror the policy through nixpkgs.config instead of
  # dropping the package.  .NET 6 is EOL upstream; the host pins it for EIDE and
  # runtime compatibility.
  nixpkgs.config = {
    allowUnfree = true;
    permittedInsecurePackages = [ "dotnet-runtime-6.0.36" ];
  };

  # WHY: converge the guest to the latest flake state after boot.  User-scoped, and
  # the generic `username` resolves to the real per-VM user at injection time.
  systemd.services.nucleus-rebuild =
    let
      flakeDir = "/home/${username}/dev/nucleus/src";
    in
    {
      description = "Rebuild NixOS system from nucleus flake";
      wantedBy = [ ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
        Group = "users";
        Environment = "HOME=/home/${username}";
      };
      script = ''
        ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ${flakeDir}#NixOS
      '';
    };

  # WHY: hosts/NixOS/base.nix pins system.stateVersion to the real host's "24.11".
  # This image builds fresh against the pinned nixpkgs, so force the newer guest
  # stateVersion rather than letting the two plain definitions collide.
  system.stateVersion = lib.mkForce "25.05";
}
