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
{
  modulesPath,
  guestUsername ? builtins.getEnv "NUCLEUS_VM_GUEST_USERNAME",
  guestPassword ? builtins.getEnv "NUCLEUS_VM_GUEST_PASSWORD",
  ...
}:
{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  networking.hostName = "NixOS";

  # VirtioFS sharing is configured after first boot when the host actually
  # exposes a shared directory. Do not force virtio_fs into the initrd here:
  # current aarch64 guest kernels may not ship it as a standalone module, which
  # breaks image generation before the VM ever boots.
  # Example guest-side mount after first boot:
  #   fileSystems."/home/nixos/dev" = { device = "dev"; fsType = "virtiofs"; };

  users.users."${guestUsername}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = guestPassword;
  };

  system.stateVersion = "25.05";
}
