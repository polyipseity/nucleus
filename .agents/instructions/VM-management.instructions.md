---
description: "Use when adding, editing, or reviewing virtual machine provisioning in scripts/vm-setup.sh, scripts/vm-setup.ps1, src/hosts/nixos/VMs.nix, src/hosts/windows/modules/system/Invoke-VMSetup.ps1, src/modules/VMs.json, vms/nixos/, or vms/windows/."
name: "VM Management"
applyTo: "scripts/vm-setup.sh, scripts/vm-setup.ps1, src/hosts/nixos/VMs.nix, src/hosts/macbook/VMs.nix, src/hosts/windows/modules/system/Invoke-VMSetup.ps1, src/modules/VMs.json, tests/nix/vm-setup-tests.nix, vms/nixos/guest.nix, vms/nixos/packer.pkr.hcl, vms/windows/packer.pkr.hcl, vms/windows/Autounattend.xml"
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

Pre-built images land in `~/virtual machines/images/<name>.qcow2`
(Windows: `%USERPROFILE%\virtual machines\images\<name>.qcow2`).
`nucleus-vm-setup` builds these images in phase 1 (if absent) and copies them to the disk location in phase 2.

QCOW2 enables copy-based migration between hosts without conversion.

## macOS — UTM

- VM backend: UTM 4.x QEMU backend.
- Bundle location: `~/virtual machines/<name>.utm/`
- Config template: `config.plist` pre-generated at
  `~/.local/share/nucleus/vms/<name>-config.plist` by `src/hosts/macbook/VMs.nix`
  at Home Manager activation time; `vm-setup.sh` copies it into the bundle.
- Disk pre-created in `Images/disk-main.qcow2` by copying the pre-built image from the images directory.
- After provisioning, UTM opens each bundle automatically.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: Shared (NAT) mode on all VMs.
- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.
- Configure script: `~/virtual machines/<name>-configure.sh` written on first provisioning.

## NixOS — libvirt/KVM

- VM infrastructure declared in `src/hosts/nixos/VMs.nix` (system module).
- Package: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd` in `environment.systemPackages`.
- User groups: `kvm` and `libvirtd` added to the managed user via `lib.mkAfter` in `VMs.nix`.
- Domain XML pre-generated at `/etc/nucleus/vms/<name>-domain.xml` by `src/hosts/nixos/VMs.nix`
  at NixOS activation time; `vm-setup.sh` calls `virsh define` on the pre-generated file (idempotent).
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
- VirtioFS on Windows requires `virtiofsd` running as a separate process before the VM starts.
  See the comment in the generated start script for the exact command.
- Configure script: `%USERPROFILE%\virtual machines\<name>-configure.sh` written on first provisioning.

## Apply Hook

`nucleus-vm-setup` (and the `--vm-setup` flag for `nucleus apply`) is **opt-in**:

- POSIX: `src/scripts/apply.sh` passes `--vm-setup` to enable; skipped by default.
- Windows: `src/hosts/windows/apply.ps1` uses `-VMSetup` switch; skipped by default.

The hook is always best-effort: a VM setup failure does not abort a completed system apply.

## Adding a New VM

1. Add an entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm-setup` on all three host platforms.
3. Add a test in `tests/nix/vm-setup-tests.nix` if the new VM has platform-specific constraints.
4. Update `src/hosts/<platform>/MANUAL.md` if the VM requires manual steps.

## VM Image Building

`nucleus-vm-setup` is a two-phase command. Phase 1 builds QCOW2 OS images (if absent); phase 2 provisions VM bundles/domains from those images.

### Files

| File                                                  | Purpose                                                        |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `vms/nixos/guest.nix`                                 | NixOS guest configuration for `nixos-generators` (macOS/NixOS) |
| `vms/nixos/packer.pkr.hcl`                            | Packer template for NixOS guest on Windows hosts               |
| `vms/windows/packer.pkr.hcl`                          | Packer template for Windows 11 guest on all hosts              |
| `vms/windows/Autounattend.xml`                        | Windows 11 answer file (unattended install, TPM bypass, WinRM) |
| `scripts/vm-setup.sh`                                 | Unified build+provision script for macOS and NixOS hosts       |
| `scripts/vm-setup.ps1`                                | Windows wrapper calling `Invoke-VMSetup.ps1`                   |
| `src/hosts/windows/modules/system/Invoke-VMSetup.ps1` | Build + provision logic for Windows hosts                      |

### Build strategies

**NixOS guest on macOS/NixOS** (`nucleus-vm-setup --nixos-only`):

- Uses `nix run github:nix-community/nixos-generators` to build from `vms/nixos/guest.nix`.
- Architecture-aware: `qcow-efi` (UEFI) on aarch64 hosts (UTM on Apple Silicon), `qcow` (BIOS) on x86_64.
- No Packer required; just `nix` command which is always present.

**NixOS guest on Windows** (`nucleus-vm-setup --nixos-only`):

- Uses Packer with `vms/nixos/packer.pkr.hcl` and QEMU builder.
- Downloads NixOS minimal ISO, boots via QEMU, sets root password, SSH-installs NixOS.
- `whpx` accelerator strongly recommended (Windows Hypervisor Platform); `tcg` works but is very slow.

**Windows 11 guest (all hosts)** (`nucleus-vm-setup --windows-only --windows-iso /path/to/Win11.iso`):

- Uses Packer with `vms/windows/packer.pkr.hcl` and QEMU builder.
- Requires a Windows 11 ISO (download from https://www.microsoft.com/software-download/windows11).
- SATA disk during build → VirtIO drivers installed post-install → final image is VirtIO-disk ready.
- Autounattend.xml bypasses TPM/Secure Boot checks, enables WinRM for Packer, creates `packer` account.
- Change the `packer` password and apply the nucleus Windows config after first boot.

### Image location

Images land at:

- macOS/NixOS: `~/virtual machines/images/<name>.qcow2`
- Windows: `%USERPROFILE%\virtual machines\images\<name>.qcow2`

Delete an image and re-run `nucleus-vm-setup` to rebuild from scratch.

### Packer requirements

- Packer installed as `pkgs.packer` (POSIX) / `HashiCorp.Packer` WinGet (Windows).
- QEMU available (existing `pkgs.qemu` on POSIX / Scoop on Windows).
- Windows builds only: `winrm_timeout = "3h"` — builds can take 30–90 minutes.

## Removing a VM

1. Remove the entry from `src/modules/VMs.json`.
2. Manually delete the disk image and registration:
   - macOS: delete `<name>.utm` bundle from UTM document store.
   - NixOS: run `virsh undefine <name>` then delete `~/virtual machines/<name>.qcow2`.
   - Windows: delete `%USERPROFILE%\virtual machines\<name>.qcow2` and the start script.
