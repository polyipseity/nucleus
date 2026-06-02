# src/vms/nixos/guest.nix — NixOS guest configuration for nixos-generators.
#
# Builds a development-ready NixOS system suitable for use as a QEMU/KVM or UTM
# VM guest, with full parity to the NixOS host configuration (excluding AI models
# and hypervisor infrastructure).  Used by scripts/vm-setup.sh on macOS and NixOS
# hosts via:
#
#   nix run github:nix-community/nixos-generators -- \
#     --format qcow           \  # qcow-efi on aarch64 hosts (UTM/virt machine)
#     --system x86_64-linux   \  # or aarch64-linux on Apple Silicon
#     --configuration ./src/vms/nixos/guest.nix \
#     -o <output-dir>
#
# On Windows hosts, src/hosts/Windows/modules/system/Invoke-VMSetup.ps1 uses
# src/vms/nixos/packer.pkr.hcl instead, which generates a similar configuration
# inline during a Packer QEMU build.
#
# Do NOT declare fileSystems, boot.loader, or hardware-configuration here:
# nixos-generators injects the correct disk/bootloader setup automatically for
# the chosen format (qcow = BIOS + ext4, qcow-efi = UEFI + ext4).
#
# Excludes:
# - src/hosts/NixOS/ai.nix — no AI models inside VMs
# - src/hosts/NixOS/vms.nix — no hypervisor/nested VM support needed
# - src/hosts/NixOS/hardware/* — qemu-guest.nix handles virtualized hardware
# - src/hosts/NixOS/jellyfin.nix — singleton media server not guest-appropriate
#
# Source: https://github.com/nix-community/nixos-generators
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  guestUsername = builtins.getEnv "NUCLEUS_VM_GUEST_USERNAME";
  guestPassword = builtins.getEnv "NUCLEUS_VM_GUEST_PASSWORD";
in
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    # Shared POSIX modules from src/modules/
    ../../src/modules/core.nix
    ../../src/modules/gnupg.nix
    ../../src/modules/posix-base.nix
    ../../src/modules/posix-security.nix
    ../../src/modules/posix-sops.nix
    ../../src/modules/posix-user-shell.nix
    # NixOS host modules (excluding vms, hardware, ai, jellyfin infrastructure)
    ../../src/hosts/NixOS/base.nix
    ../../src/hosts/NixOS/desktop.nix
    ../../src/hosts/NixOS/networking.nix
    ../../src/hosts/NixOS/security.nix
    ../../src/hosts/NixOS/sops.nix
    ../../src/hosts/NixOS/users.nix
  ];

  networking.hostName = "NixOS";

  # VirtioFS sharing is configured after first boot when the host actually
  # exposes a shared directory. Do not force virtio_fs into the initrd here:
  # current aarch64 guest kernels may not ship it as a standalone module, which
  # breaks image generation before the VM ever boots.
  # Example guest-side mount after first boot:
  #   fileSystems."/home/<guest-user>/dev" = { device = "dev"; fsType = "virtiofs"; };

  users.users."${guestUsername}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = guestPassword;
    openssh.authorizedKeys.keys = [ (builtins.getEnv "NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY") ];
  };

  services.qemuGuest.enable = true;
  services.openssh.enable = true;

  systemd.services.nucleus-rebuild =
    let
      flakeDir = "/home/${guestUsername}/dev/nucleus/src";
    in
    {
      description = "Rebuild NixOS system from nucleus flake";
      wantedBy = [ ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = guestUsername;
        Group = "users";
        Environment = "HOME=/home/${guestUsername}";
      };
      script = ''
        ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ${flakeDir}#NixOS
      '';
    };

  system.stateVersion = "25.05";
}
