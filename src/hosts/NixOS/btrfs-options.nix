# hosts/NixOS/btrfs-options.nix — Shared Btrfs mount options for NixOS host and guest images.
_: {
  root = [
    "subvol=@"
    "compress-force=zstd"
    "noatime"
  ];
  nix = [
    "subvol=@nix"
    "compress-force=zstd"
    "noatime"
  ];
}
