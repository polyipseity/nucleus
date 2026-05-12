# hosts/nixos/hardware/disks.nix — Disk-related hardware defaults for CI-safe evaluation.
#
# This host profile is a template until real hardware-configuration.nix values
# are merged. NixOS requires a root filesystem and bootloader device during
# evaluation; mkDefault placeholders keep flake checks green while allowing
# real machine values to override these defaults later.
{ lib, ... }:
{
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  boot.loader.grub.devices = lib.mkDefault [ "/dev/sda" ];
}
