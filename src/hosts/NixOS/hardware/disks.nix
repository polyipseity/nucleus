# hosts/NixOS/hardware/disks.nix — Disk-related hardware defaults for CI-safe evaluation.
#
# This host profile is a template until real hardware-configuration.nix values
# are merged. NixOS requires a root filesystem and bootloader device during
# evaluation; mkDefault placeholders keep flake checks green while allowing
# real machine values to override these defaults later.
#
# First install: partition with Btrfs, create subvolumes @ (root) and @nix
# (/nix), mount @ at /mnt and @nix at /mnt/nix, then nixos-install. Run
# nixos-generate-config after install and merge host-specific facts (UUIDs,
# EFI /boot, swap, bootloader device paths) into this file. See MANUAL.md.
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

  # Uncomment and set device after install when merging hardware-configuration.nix:
  # fileSystems."/boot" = lib.mkDefault {
  #   device = "/dev/disk/by-partlabel/EFI";
  #   fsType = "vfat";
  # };

  boot.loader.grub.devices = lib.mkDefault [ "/dev/sda" ];
}
