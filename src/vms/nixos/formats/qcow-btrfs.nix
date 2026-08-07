# vms/nixos/formats/qcow-btrfs.nix — qcow2 BIOS/hybrid guest image with Btrfs root.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    "${toString modulesPath}/profiles/qemu-guest.nix"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "btrfs";
  };

  boot.growPartition = true;
  boot.initrd.supportedFilesystems = [ "btrfs" ];
  boot.kernelParams = [ "console=ttyS0" ];
  boot.loader.grub.device =
    if (pkgs.stdenv.system == "x86_64-linux") then
      (lib.mkDefault "/dev/vda")
    else
      (lib.mkDefault "nodev");
  boot.loader.grub.efiSupport = lib.mkIf (pkgs.stdenv.system != "x86_64-linux") (lib.mkDefault true);
  boot.loader.grub.efiInstallAsRemovable = lib.mkIf (pkgs.stdenv.system != "x86_64-linux") (
    lib.mkDefault true
  );
  boot.loader.timeout = 0;

  system.build.qcow-btrfs = import ../disk-image/make-btrfs-disk-image.nix {
    inherit
      lib
      config
      pkgs
      modulesPath
      ;
    inherit (config.virtualisation) diskSize;
    format = "qcow2";
    fsType = "btrfs";
    partitionTableType = "hybrid";
  };

  formatAttr = "qcow-btrfs";
  fileExtension = ".qcow2";
}
