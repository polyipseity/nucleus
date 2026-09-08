---
description: "Use when editing host disk layout, root filesystem declarations, removable-drive mount policy, or bootstrap-only filesystem steps on MacBook, NixOS, or Windows."
name: "Host Filesystem Scope"
applyTo: "src/hosts/**, scripts/bootstrap.*, src/vms/NixOS/**"
---

# Host filesystem scope

What nucleus manages at apply time, what stays on OS defaults, and bootstrap-only steps.

## Managed at apply

| Concern | MacBook | NixOS | Windows |
| ------- | ------- | ----- | ------- |
| Root / block layout | — (APFS defaults) | [`fileSystems`](../../src/hosts/NixOS/hardware/disks.nix), [`filesystems.nix`](../../src/hosts/NixOS/filesystems.nix) | — (NTFS defaults) |
| Removable NTFS RW | fuse-t + ntfs-3g + Mounty ([`homebrew.nix`](../../src/hosts/MacBook/homebrew.nix), [`ntfs-3g.nix`](../../src/hosts/MacBook/ntfs-3g.nix)) | ntfs-3g via udisks2/GVFS ([`filesystems.nix`](../../src/hosts/NixOS/filesystems.nix), [`desktop.nix`](../../src/hosts/NixOS/desktop.nix)) | native NTFS |
| Cloud FUSE mounts | rclone + FUSE-T ([`cloud-drives.nix`](../../src/modules/cloud-drives.nix)) | rclone + fuse3 | rclone + WinFsp ([`packages.dsc.yml`](../../src/hosts/Windows/system/packages.dsc.yml)) |
| VM disk container | QCOW2 ([`VMs.json`](../../src/modules/VMs.json), [`vm-management.instructions.md`](vm-management.instructions.md)) | QCOW2 + VirtioFS host share | QCOW2 |
| Storage hygiene | Finder Trash prune ([`defaults.nix`](../../src/hosts/MacBook/defaults.nix)) | — | Storage Sense ([`storage-sense.dsc.yml`](../../src/hosts/Windows/system/storage-sense.dsc.yml)) |
| Long paths | — | — | [`long-paths.dsc.yml`](../../src/hosts/Windows/system/long-paths.dsc.yml) |

## Not managed (defaults desired)

- **MacBook:** APFS/HFS+ layout, container sizing, FileVault. **Windows:** NTFS layout, BitLocker, partition tables. Neither repartitions or reformats during `nucleus-apply`.
- **All hosts:** disk encryption (FileVault / BitLocker / LUKS) stays as installer or manual decisions.

## Bootstrap-only (MacBook)

`/nix` requires APFS synthetic mount via `/etc/synthetic.conf`. [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) `ensure_macos_nix_mount` appends `nix` when missing; exits until reboot. `nucleus-apply` never modifies `/etc/synthetic.conf`.

## First-install (NixOS)

After bare-metal install: `nixos-generate-config`, merge host-specific facts into [`src/hosts/NixOS/hardware/`](../../src/hosts/NixOS/hardware/). Root must be **Btrfs** with options from [`disks.nix`](../../src/hosts/NixOS/hardware/disks.nix). See [`MANUAL.md`](../../src/hosts/NixOS/MANUAL.md).

## Desired root filesystem defaults

| Host | Root FS | Rationale |
| ---- | ------- | --------- |
| MacBook | APFS (+ HFS+ legacy local folders) | macOS platform default; not configurable via nix-darwin |
| NixOS | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`, `noatime`) | snapshots, compression, scrubbing |
| NixOS guest | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`) | parity with host; see [`src/vms/NixOS/formats/`](../../src/vms/NixOS/formats/) |
| Windows | NTFS | platform default; well supported for dev workloads |
