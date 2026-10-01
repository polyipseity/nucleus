# hosts/NixOS/hardware/disks.nix — Disk-related hardware defaults for CI-safe evaluation.
#
# Template until real hardware-configuration.nix values are merged. NixOS needs a
# root filesystem and a bootloader device during evaluation, so mkDefault
# placeholders keep flake checks green while a real machine overrides them.
#
# First install: partition with Btrfs, create @ (root) and @nix (/nix), mount @
# at /mnt and @nix at /mnt/nix, then nixos-install. Run nixos-generate-config
# after install and merge UUIDs, EFI /boot, swap, and bootloader paths here.
{ lib, ... }:
let
  btrfsOptions = import ../btrfs-options.nix { };
in
{
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOptions.root;
  };

  fileSystems."/nix" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = btrfsOptions.nix;
    neededForBoot = true;
  };

  # Uncomment and set after merging hardware-configuration.nix:
  # fileSystems."/boot" = lib.mkDefault {
  #   device = "/dev/disk/by-partlabel/EFI";
  #   fsType = "vfat";
  # };

  boot.loader.grub.devices = lib.mkDefault [ "/dev/sda" ];
}
