---
description: "Use when editing host disk layout, root filesystem declarations, removable-drive mount policy, or bootstrap-only filesystem steps."
name: "Host Filesystem Scope"
applyTo: "src/hosts/**, scripts/bootstrap.*, src/vms/NixOS/**"
---

# Host filesystem scope

## Not managed

Disk encryption (FileVault, BitLocker, LUKS) is an installer or manual decision; `nucleus-apply` never repartitions or reformats. MacBook keeps APFS/HFS+ layout, container sizing, and FileVault. Windows keeps NTFS layout, BitLocker, and partition tables.

## Desired root filesystem

| Host | Root FS | Rationale |
| --- | --- | --- |
| MacBook | APFS (+ HFS+ legacy local folders) | macOS default, not configurable via nix-darwin |
| NixOS | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`, `noatime`) | snapshots, compression, scrubbing |
| NixOS guest | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`) | parity with host; `src/vms/NixOS/formats/` |
| Windows | NTFS | platform default, well supported for dev |

## Bootstrap only, MacBook

`/nix` needs an APFS synthetic mount: `ensure_macos_nix_mount` in `scripts/bootstrap.sh` appends `nix` to `/etc/synthetic.conf` when missing and exits until reboot. `nucleus-apply` never touches that file.

## First install, NixOS

After bare-metal install, merge `nixos-generate-config` output into `src/hosts/NixOS/hardware/`. Root must be Btrfs with the options in `src/hosts/NixOS/hardware/disks.nix`. See `src/hosts/NixOS/MANUAL.md`.
