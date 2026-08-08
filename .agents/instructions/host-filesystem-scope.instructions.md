---
description: "Use when editing host disk layout, root filesystem declarations, removable-drive mount policy, or bootstrap-only filesystem steps on MacBook, NixOS, or Windows."
name: "Host Filesystem Scope"
applyTo: "src/hosts/**, scripts/bootstrap.*, src/vms/nixos/**"
---

# Host filesystem scope

Single source of truth for what nucleus manages at apply time versus what remains on OS defaults or install/bootstrap workflows.

## Managed at apply

| Concern | MacBook | NixOS | Windows |
| ------- | ------- | ----- | ------- |
| Root / block layout | — (APFS defaults) | [`fileSystems`](../../src/hosts/NixOS/hardware/disks.nix), [`filesystems.nix`](../../src/hosts/NixOS/filesystems.nix) | — (NTFS defaults) |
| Removable NTFS RW | fuse-t + ntfs-3g + Mounty ([`homebrew.nix`](../../src/hosts/MacBook/homebrew.nix), [`ntfs-3g.nix`](../../src/hosts/MacBook/ntfs-3g.nix)) | ntfs-3g via udisks2/GVFS ([`filesystems.nix`](../../src/hosts/NixOS/filesystems.nix), [`desktop.nix`](../../src/hosts/NixOS/desktop.nix)) | native NTFS |
| Cloud FUSE mounts | rclone + FUSE-T ([`cloud-drives.nix`](../../src/modules/cloud-drives.nix)) | rclone + fuse3 | rclone + WinFsp ([`packages.dsc.yml`](../../src/hosts/Windows/system/packages.dsc.yml)) |
| VM disk container | QCOW2 ([`VMs.json`](../../src/modules/VMs.json), [`vm-management.instructions.md`](vm-management.instructions.md)) | QCOW2 + VirtioFS host share | QCOW2 |
| Storage hygiene policy | Finder Trash prune ([`defaults.nix`](../../src/hosts/MacBook/defaults.nix)) | — | Storage Sense ([`storage-sense.dsc.yml`](../../src/hosts/Windows/system/storage-sense.dsc.yml)) |
| Long paths | — | — | [`long-paths.dsc.yml`](../../src/hosts/Windows/system/long-paths.dsc.yml) |

## Not managed (defaults are desired)

- **MacBook:** APFS/HFS+ system volume layout, container sizing, FileVault policy. Nucleus does not repartition or reformat disks during `nucleus-apply`.
- **Windows:** NTFS system volume layout, BitLocker policy, partition tables. Nucleus does not repartition or reformat disks during `nucleus-apply`.
- **All hosts:** disk encryption choices (FileVault / BitLocker / LUKS) remain installer or manual operator decisions unless a future host module explicitly adds them.

## Bootstrap-only (MacBook)

`/nix` on macOS requires an APFS synthetic mount via `/etc/synthetic.conf`. [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) `ensure_macos_nix_mount` appends `nix` when missing and exits until the operator reboots. `nucleus-apply` never modifies `/etc/synthetic.conf`.

## First-install (NixOS)

After bare-metal install, run `nixos-generate-config` and merge host-specific facts (filesystem UUIDs, EFI `/boot`, swap, bootloader devices) into [`src/hosts/NixOS/hardware/`](../../src/hosts/NixOS/hardware/). Root must be **Btrfs** with the options declared in [`disks.nix`](../../src/hosts/NixOS/hardware/disks.nix). See [`MANUAL.md`](../../src/hosts/NixOS/MANUAL.md).

## Desired root filesystem defaults

| Host | Root FS | Rationale |
| ---- | ------- | --------- |
| MacBook | APFS (+ HFS+ legacy local folders) | macOS platform default; not configurable via nix-darwin |
| NixOS | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`, `noatime`) | snapshots, compression, scrubbing |
| NixOS guest | Btrfs (`subvol=@` + `subvol=@nix`, `compress-force=zstd`) | parity with host; see [`src/vms/nixos/formats/`](../../src/vms/nixos/formats/) |
| Windows | NTFS | platform default; well supported for dev workloads |
