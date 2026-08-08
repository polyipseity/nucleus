# vms/NixOS/disk-image/make-btrfs-disk-image.nix — Btrfs-capable fork of nixpkgs make-disk-image.nix.
#
# Upstream make-disk-image.nix only supports partitioned layouts with ext4
# (mkfs.ext4 -E offset=...). Nucleus guest images use hybrid/EFI partition
# tables with a Btrfs root, so this wrapper patches the upstream module at eval
# time. For btrfs, staging is copied into @/@nix subvolumes (not cptofs onto
# subvolid=5). Delete this fork once nixpkgs accepts partitioned Btrfs images upstream.
{ modulesPath, pkgs, ... }@args:
let
  upstreamPath = "${toString modulesPath}/../lib/make-disk-image.nix";
  patchedSource =
    pkgs.runCommandLocal "make-btrfs-disk-image.nix"
      {
        nativeBuildInputs = [ pkgs.patch ];
        src = pkgs.writeText "make-disk-image.nix" (builtins.readFile upstreamPath);
        patches = [ ./make-disk-image-btrfs.patch ];
      }
      ''
        cp "$src" "$out"
        patch -p1 "$out" < "$patches"
      '';
in
import patchedSource (
  args
  // {
    fsType = args.fsType or "btrfs";
  }
)
