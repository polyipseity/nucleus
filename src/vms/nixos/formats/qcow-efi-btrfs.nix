# vms/nixos/formats/qcow-efi-btrfs.nix — qcow2 UEFI guest image with Btrfs root.
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

  options.boot.consoles = lib.mkOption {
    default = [
      "ttyS0"
    ]
    ++ (lib.optional (pkgs.stdenv.hostPlatform.isAarch) "ttyAMA0,115200")
    ++ (lib.optional (pkgs.stdenv.hostPlatform.isRiscV64) "ttySIF0,115200");
    description = "Kernel console boot flags to pass to boot.kernelParams";
    example = [ "ttyS2,115200" ];
  };

  config = {
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "btrfs";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
    };

    boot.growPartition = true;
    boot.initrd.supportedFilesystems = [ "btrfs" ];
    boot.kernelParams = map (c: "console=${c}") config.boot.consoles;
    boot.loader.grub.device = "nodev";
    boot.loader.grub.efiSupport = true;
    boot.loader.grub.efiInstallAsRemovable = true;
    boot.loader.timeout = 0;

    system.build.qcow-efi-btrfs = import ../disk-image/make-btrfs-disk-image.nix {
      inherit
        lib
        config
        pkgs
        modulesPath
        ;
      inherit (config.virtualisation) diskSize;
      format = "qcow2";
      fsType = "btrfs";
      partitionTableType = "efi";
    };

    formatAttr = "qcow-efi-btrfs";
    fileExtension = ".qcow2";
  };
}
