---
description: "Use when editing host disk layout, root filesystem declarations, removable-drive mount policy, or bootstrap-only filesystem steps on MacBook, NixOS, or Windows."
name: "Host Filesystem Scope"
applyTo: "src/hosts/**, scripts/bootstrap.*, src/vms/NixOS/**"
---

# Host filesystem scope

## Not managed

Disk encryption (FileVault, BitLocker, LUKS) is an installer or manual decision, and `nucleus-apply` never repartitions or reformats. MacBook keeps APFS/HFS+ layout, container sizing, and FileVault; Windows keeps NTFS layout, BitLocker, and partition tables.

## Desired root filesystem

| Host | Root FS | Rationale |
| ---- | ------- | --------- |
| MacBook | APFS (+ HFS+ legacy local folders) | macOS platform default; not configurable via nix-darwin |
| NixOS | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`, `noatime`) | snapshots, compression, scrubbing |
| NixOS guest | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`) | parity with host; see `src/vms/NixOS/formats/` |
| Windows | NTFS | platform default; well supported for dev workloads |

## Bootstrap-only (MacBook)

`/nix` needs an APFS synthetic mount, so `ensure_macos_nix_mount` in `scripts/bootstrap.sh` appends `nix` to `/etc/synthetic.conf` when missing and exits until reboot. `nucleus-apply` never touches `/etc/synthetic.conf`.

## First install (NixOS)

After bare-metal install, merge the output of `nixos-generate-config` into `src/hosts/NixOS/hardware/`. Root must be Btrfs with the options from `src/hosts/NixOS/hardware/disks.nix`. See `src/hosts/NixOS/MANUAL.md`.
