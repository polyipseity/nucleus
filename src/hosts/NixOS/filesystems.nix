# hosts/NixOS/filesystems.nix — Filesystem driver and removable-mount policy.
{ pkgs, ... }: {
  boot.supportedFilesystems = [
    "ntfs"
    "vfat"
  ];
  boot.initrd.supportedFilesystems = [ "btrfs" ];

  environment.systemPackages = [ pkgs.duperemove ];

  # NTFS read/write for removable drives is handled by GNOME's built-in
  # udisks2 and GVFS, using ntfs-3g (FUSE) — active via boot.supportedFilesystems
  # above plus the nixpkgs base profile.
  # The in-kernel ntfs3 driver (built-in since Linux 5.15) is NOT used:
  # partitions left "dirty" by Windows fast-startup refuse mount without
  # `force`, and making udisks2 prefer ntfs3 requires a udev rule that Arch
  # Wiki recommends against ("can confuse some 3rd party tools").
  # ntfs-3g handles dirty volumes gracefully with no compatibility issues.
  # https://wiki.archlinux.org/title/NTFS#unknown_filesystem_type_'ntfs'
}
