---
description: "Use when editing host disk layout, root filesystem declarations, removable-drive mount policy, or bootstrap-only filesystem steps."
name: "Host Filesystem Scope"
applyTo: "src/hosts/**, scripts/bootstrap.*, src/vms/NixOS/**"
---

# Host filesystem scope

Disk encryption is installer or manual; `nucleus-apply` never repartitions or reformats. MacBook keeps APFS/HFS+ and FileVault; Windows keeps NTFS, BitLocker, and partition tables. Root filesystems: MacBook APFS, NixOS Btrfs (`subvol=@`, `subvol=@nix`, `compress-force=zstd`, `noatime`), NixOS guest Btrfs without `noatime`, Windows NTFS.

MacBook `/nix` needs an APFS synthetic mount, so `ensure_macos_nix_mount` appends `nix` to `/etc/synthetic.conf` and exits until reboot; apply never touches that file. After a bare-metal NixOS install, merge `nixos-generate-config` output into `src/hosts/NixOS/hardware/` and keep the Btrfs options from `disks.nix`.

Details: `.agents/skills/nucleus-platform-reference/references/host-filesystem-scope.md`.
