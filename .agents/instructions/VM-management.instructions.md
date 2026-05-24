---
description: "Use when adding, editing, or reviewing virtual machine provisioning in scripts/VM-setup.sh, scripts/VM-setup.ps1, src/hosts/nixos/VMs.nix, src/hosts/windows/modules/system/Invoke-VMSetup.ps1, or src/modules/VMs.json."
name: "VM Management"
applyTo: "scripts/VM-setup.sh, scripts/VM-setup.ps1, src/hosts/nixos/VMs.nix, src/hosts/macbook/VMs.nix, src/hosts/windows/modules/system/Invoke-VMSetup.ps1, src/modules/VMs.json, tests/nix/VM-setup-tests.nix"
---

# VM Management

## VM Manifest

All virtual machines are declared in `src/modules/VMs.json`.
This is the single source of truth for VM names, resources, and options consumed by all three platform
setup scripts.

Required fields for each VM entry:

| Field         | Type   | Description                                           |
| ------------- | ------ | ----------------------------------------------------- |
| `name`        | string | Machine-readable identifier used as file/domain name  |
| `display`     | string | Human-readable name shown in UTM/virt-manager         |
| `cpus`        | int    | Number of virtual CPUs                                |
| `ramMiB`      | int    | RAM in MiB                                            |
| `diskGiB`     | int    | Boot disk size in GiB                                 |
| `type`        | string | Guest OS family: `"nixos"`, `"windows"`, or `"linux"` |
| `shareDevDir` | bool   | Mount `~/dev` inside the guest via VirtioFS           |

## Disk Format

QCOW2 throughout all three platforms.
Stored at:

- macOS: `~/virtual machines/<name>.utm/Images/disk-main.qcow2`
- NixOS: `~/virtual machines/<name>.qcow2`
- Windows: `%USERPROFILE%\virtual machines\<name>.qcow2`

QCOW2 enables copy-based migration between hosts without conversion.

## macOS — UTM

- VM backend: UTM 4.x QEMU backend.
- Bundle location: `~/virtual machines/<name>.utm/`
- Config template: `config.plist` pre-generated at
  `~/.local/share/nucleus/vms/<name>-config.plist` by `src/hosts/macbook/VMs.nix`
  at Home Manager activation time; `VM-setup.sh` copies it into the bundle.
- Disk pre-created in `Images/disk-main.qcow2` using `qemu-img` (from `pkgs.qemu` via nixpkgs).
- After provisioning, UTM opens each bundle automatically; attach an installation ISO to install the guest OS.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: Shared (NAT) mode on all VMs.
- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.
- Configure script: `~/virtual machines/<name>-configure.sh` written on first provisioning.

## NixOS — libvirt/KVM

- VM infrastructure declared in `src/hosts/nixos/VMs.nix` (system module).
- Package: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd` in `environment.systemPackages`.
- User groups: `kvm` and `libvirtd` added to the managed user via `lib.mkAfter` in `VMs.nix`.
- Domain XML pre-generated at `/etc/nucleus/vms/<name>-domain.xml` by `src/hosts/nixos/VMs.nix`
  at NixOS activation time; `VM-setup.sh` calls `virsh define` on the pre-generated file (idempotent).
- VirtioFS shared directory: uses `virtiofsd` daemon; configured in the XML domain definition.
- SPICE display + clipboard sharing enabled by default.
- OVMF firmware (UEFI) and swtpm (TPM 2.0) enabled for Windows 11 compatibility.
- After provisioning, run `virt-manager` to attach an installation ISO.
- Configure script: `~/virtual machines/<name>-configure.sh` written on first provisioning.

## Windows — QEMU via Scoop

- QEMU installed via Scoop extras bucket by `Invoke-ScoopSetup.ps1`.
  - `qemu-img.exe`: disk creation.
  - `qemu-system-x86_64.exe` / `qemu-system-aarch64.exe`: VM launch.
- Disk images and generated start scripts placed in `%USERPROFILE%\virtual machines\`.
- Start script: `Start-<display>.ps1` — a self-contained PowerShell launch command.
  To install a guest OS, add `-cdrom 'C:\path\to\install.iso'` to the start script.
- VirtioFS on Windows requires `virtiofsd` running as a separate process before the VM starts.
  See the comment in the generated start script for the exact command.
- Configure script: `%USERPROFILE%\virtual machines\<name>-configure.sh` written on first provisioning.

## Apply Hook

`nucleus-VM-setup` (and the `--VM-setup` flag for `nucleus apply`) is **opt-in**:

- POSIX: `src/scripts/apply.sh` passes `--VM-setup` to enable; skipped by default.
- Windows: `src/hosts/windows/apply.ps1` uses `-VMSetup` switch; skipped by default.

The hook is always best-effort: a VM setup failure does not abort a completed system apply.

## Adding a New VM

1. Add an entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-VM-setup` on all three host platforms.
3. Add a test in `tests/nix/VM-setup-tests.nix` if the new VM has platform-specific constraints.
4. Update `src/hosts/<platform>/MANUAL.md` if the VM requires manual steps (ISO attachment, etc.).

## Removing a VM

1. Remove the entry from `src/modules/VMs.json`.
2. Manually delete the disk image and registration:
   - macOS: delete `<name>.utm` bundle from UTM document store.
   - NixOS: run `virsh undefine <name>` then delete `~/virtual machines/<name>.qcow2`.
   - Windows: delete `%USERPROFILE%\virtual machines\<name>.qcow2` and the start script.
