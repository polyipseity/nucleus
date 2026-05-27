# vms/nixos/guest.nix — NixOS guest configuration for nixos-generators.
#
# Builds a minimal, development-ready NixOS system suitable for use as a
# QEMU/KVM or UTM VM guest.  Used by scripts/VM-build.sh on macOS and NixOS
# hosts via:
#
#   nix run github:nix-community/nixos-generators -- \
#     --format qcow           \  # qcow-efi on aarch64 hosts (UTM/virt machine)
#     --system x86_64-linux   \  # or aarch64-linux on Apple Silicon
#     --configuration ./vms/nixos/guest.nix \
#     -o <output-dir>
#
# On Windows hosts, scripts/VM-build.ps1 uses vms/nixos/packer.pkr.hcl instead,
# which generates a similar configuration inline during a Packer QEMU build.
#
# Do NOT declare fileSystems, boot.loader, or hardware-configuration here:
# nixos-generators injects the correct disk/bootloader setup automatically for
# the chosen format (qcow = BIOS + ext4, qcow-efi = UEFI + ext4).
#
# Source: https://github.com/nix-community/nixos-generators
{ modulesPath, pkgs, ... }:
{
  imports = [
    # VirtIO drivers for disk, network, memory balloon, and random number
    # generator.  Needed for high-performance operation under QEMU/KVM.
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  networking.hostName = "NixOS";

  # VirtioFS sharing is configured after first boot when the host actually
  # exposes a shared directory. Do not force virtio_fs into the initrd here:
  # current aarch64 guest kernels may not ship it as a standalone module, which
  # breaks image generation before the VM ever boots.
  # Example guest-side mount after first boot:
  #   fileSystems."/home/nixos/dev" = { device = "dev"; fsType = "virtiofs"; };

  # SSH access for post-boot management and initial configuration.
  # Allow root login for initial setup; harden after applying the nucleus
  # host configuration (nucleus-apply) inside the VM.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Default non-root user for day-to-day use inside the VM.
  # Change the password with `passwd nixos` after first boot.
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
  };
  security.sudo.wheelNeedsPassword = false;

  # Minimal tooling present before applying the nucleus NixOS host config.
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "25.05";
}
