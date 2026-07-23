---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm-setup.*, src/hosts/*/vms.nix, src/modules/VMs.json, src/secrets/users-*.yml, tests/modules/vm-setup-tests.nix, src/vms/**"
---

# VM Management

## Host × Guest Matrix

| Host \ Guest | macOS         | NixOS           | Windows         |
| ------------ | ------------- | --------------- | --------------- |
| macOS        | Tart (Packer) | UTM 4.x (QEMU)  | UTM 4.x (QEMU)  |
| NixOS        | not supported | libvirt/KVM     | libvirt/KVM     |
| Windows      | not supported | QEMU standalone | QEMU standalone |

macOS guest uses Tart (Apple Virtualization.framework) exclusively; automated Tart→UTM runtime handoff is not supported (format mismatch, no tooling).

## Hostname convention

VM guest OSes must use the same hostname and display name as the corresponding host OS. The canonical values are:

| Guest OS | `networking.hostName` / `ComputerName` | `display` in VMs.json |
| -------- | -------------------------------------- | --------------------- |
| macOS    | (set manually inside guest)            | `MacBook`             |
| NixOS    | `NixOS`                                | `NixOS`               |
| Windows  | `Windows`                              | `Windows`             |

Apply this convention when adding or modifying:

- `src/vms/nixos/guest.nix` — set `networking.hostName = "NixOS"`
- `src/vms/nixos/packer.pkr.hcl` — set `networking.hostName = "NixOS"` inline
- `src/vms/windows/Autounattend.xml` — set `<ComputerName>Windows</ComputerName>`
- `src/modules/VMs.json` — set `display` to the canonical PascalCase name

## Guest credential convention

VM guest credentials must come from per-user SOPS secrets (`src/secrets/users-<username>.yml`), not from host login or defaults.

- Keys: `vm_guest_username`, `vm_guest_password` — referenced via `vmGuest` object (`usernameSecretKey`, `passwordSecretKey`) in `src/modules/users.json` (POSIX) or `src/hosts/Windows/users.json` (Windows).
- Each setup script (`vm.sh` / `Invoke-VMSetup.ps1`) resolves the current user, reads the `vmGuest` reference, decrypts the secret, and passes credentials into guest builders/templates.
- All guest paths (NixOS: `guest.nix` + `packer.pkr.hcl`; Windows: `Autounattend.xml` + `packer.pkr.hcl`; macOS: `packer.pkr.hcl`) must consume injected credentials.
- Credential drift must invalidate stale VM artifacts so changing secret-backed values rebuilds rather than reusing stale disks.

When changing credential policy, update `tests/modules/vm-setup-tests.nix` in the same commit.

## VM manifest

All virtual machines are declared in `src/modules/VMs.json`. This is the single source of truth for VM names, resources, and options consumed by all three platform setup scripts.

Required fields for each VM entry:

| Field         | Type   | Description                                           |
| ------------- | ------ | ----------------------------------------------------- |
| `name`        | string | Machine-readable identifier used as file/domain name  |
| `display`     | string | Human-readable name shown in UTM/virt-manager         |
| `cpus`        | int    | Number of virtual CPUs                                |
| `ramBytes`    | int    | RAM in bytes                                          |
| `diskBytes`   | int    | Boot disk size in bytes                               |
| `type`        | string | Guest OS family: `"NixOS"`, `"Windows"`, or `"Linux"` |
| `shareDevDir` | bool   | Mount `~/dev` inside the guest via VirtioFS           |

Optional fields:

| Field            | Type   | Description                                                                                                                                                                                                                                                                              |
| ---------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `macOSVersion`   | string | macOS release name (e.g. `"sequoia"`). Required for `type: "macOS"` entries; used by the Tart Packer build to select the base image.                                                                                                                                                     |
| `windowsEdition` | string | Windows edition string passed to Packer (e.g. `"pro"`). Optional for `type: "Windows"` entries; defaults to `"Pro"` when absent.                                                                                                                                                         |
| `windowsIsoUrl`  | string | URL to auto-download the Windows installer ISO when `--windows-iso` is omitted. Set to a stable direct download URL (e.g. an evaluation ISO from Microsoft's Evaluation Center or an internal mirror). The downloaded ISO is cached at `~/virtual machines/images/<name>-installer.iso`. |

## Disk format

QCOW2 throughout all three platforms. Stored at:

- macOS: `~/virtual machines/<name>.utm/Data/disk-main.qcow2`
- NixOS: `~/virtual machines/<name>.qcow2`
- Windows: `%USERPROFILE%\virtual machines\<name>.qcow2`

Pre-built images land in `~/virtual machines/images/<name>.qcow2` (Windows: `%USERPROFILE%\virtual machines\images\<name>.qcow2`). `nucleus-vm setup` builds these images in phase 1 (if absent) and copies them to the disk location in phase 2.

QCOW2 enables copy-based migration between hosts without conversion.

## macOS — Tart (macOS guests)

- VM backend: Tart CLI (Apple Virtualization.framework); macOS host only.
- VM store: `~/virtual machines/.tart/vms/<name>/` — Tart's storage root (`~/.tart`) is symlinked to `~/virtual machines/.tart` by `nucleus-vm setup` so Tart artifacts co-locate with UTM bundles for unified backup.
- Build tool: Packer + `tart-cli` plugin pulling `ghcr.io/cirruslabs/macos-<version>-base:latest` from GHCR.
- Start command (after build): `tart run <name>`.
- No UTM bundle is created for macOS guests; they remain Tart-managed.

## macOS — UTM

- VM backend: UTM 4.x QEMU backend.
- Bundle location: `~/virtual machines/<name>.utm/`
- Config template: `config.plist` pre-generated at `~/.local/share/nucleus/vms/<name>-config.plist` by `src/hosts/MacBook/vms.nix` at Home Manager activation time; `vm.sh setup` copies it into the bundle.
- Disk pre-created in `Images/disk-main.qcow2` by copying the pre-built image from the images directory.
- After provisioning, UTM opens each bundle automatically.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: Shared (NAT) mode on all VMs.

- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.

## NixOS — libvirt/KVM

- VM infrastructure declared in `src/hosts/NixOS/vms.nix` (system module).
- Package: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd` in `environment.systemPackages`.
- User groups: `kvm` and `libvirtd` added to the managed user via `lib.mkAfter` in `vms.nix`.
- Domain XML pre-generated at `/etc/nucleus/vms/<name>-domain.xml` by `src/hosts/NixOS/vms.nix` at NixOS activation time; `vm.sh setup` calls `virsh define` on the pre-generated file (idempotent).
- VirtioFS shared directory: uses `virtiofsd` daemon; configured in the XML domain definition.
- SPICE display + clipboard sharing enabled by default.
- OVMF firmware (UEFI) and swtpm (TPM 2.0) enabled for Windows 11 compatibility.
- After provisioning, start the guest with the generated `start-<name>.sh` / `start-<name>.ps1` helpers (or use `virt-manager`).

## Windows — QEMU via Scoop

- QEMU installed via Scoop extras bucket by `Invoke-ScoopSetup.ps1`.
  - `qemu-img.exe`: disk creation.
  - `qemu-system-x86_64.exe` / `qemu-system-aarch64.exe`: VM launch.
- Disk images and generated start scripts placed in `%USERPROFILE%\virtual machines\`.
- Start script: `start-<name>.ps1` — a self-contained PowerShell launch command.
- VirtioFS on Windows requires `virtiofsd` running as a separate process before the VM starts. See `~/virtual machines/README.md` for the exact command.

## Apply hook

`nucleus-vm setup` (and the `--vm-setup` flag for `nucleus apply`) is opt-in:

- POSIX: `src/scripts/apply.sh` passes `--vm-setup` to enable; skipped by default.
- Windows: `src/hosts/Windows/apply.ps1` uses `-VMSetup` switch; skipped by default.

The hook is always best-effort: a VM setup failure does not abort a completed system apply.

## Adding a new VM

1. Add an entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm setup` on all three host platforms.
3. Add a test in `tests/modules/vm-setup-tests.nix` if the new VM has platform-specific constraints.
4. Update `src/hosts/<platform>/MANUAL.md` if the VM requires manual steps.

## VM image building

`nucleus-vm setup` is a two-phase command. Phase 1 builds QCOW2 OS images (if absent); phase 2 provisions VM bundles/domains from those images.

### Files

| File                                                  | Purpose                                                        |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `src/vms/nixos/guest.nix`                             | NixOS guest configuration for `nixos-generators` (macOS/NixOS) |
| `src/vms/nixos/packer.pkr.hcl`                        | Packer template for NixOS guest on Windows hosts               |
| `src/vms/windows/packer.pkr.hcl`                      | Packer template for Windows 11 guest on all hosts              |
| `src/vms/windows/Autounattend.xml`                    | Windows 11 answer file (unattended install, TPM bypass, WinRM) |
| `scripts/vm.sh`                                       | Unified build+provision script for macOS and NixOS hosts       |
| `scripts/vm.ps1`                                      | Windows wrapper calling `Invoke-VMSetup.ps1`                   |
| `src/hosts/Windows/modules/system/Invoke-VMSetup.ps1` | Build + provision logic for Windows hosts                      |

### Build strategies

**NixOS guest on macOS/NixOS**:

- Uses `nix run github:nix-community/nixos-generators` to build from `src/vms/nixos/guest.nix`.
- Architecture-aware: `qcow-efi` (UEFI) on aarch64 hosts (UTM on Apple Silicon), `qcow` (BIOS) on x86_64.
- No Packer required; just `nix` command which is always present.

**NixOS guest on Windows**:

- Uses Packer with `src/vms/nixos/packer.pkr.hcl` and QEMU builder.
- Downloads NixOS minimal ISO, boots via QEMU, sets root password, SSH-installs NixOS.
- `whpx` accelerator strongly recommended (Windows Hypervisor Platform); `tcg` works but is very slow.

**Windows 11 guest (all hosts)** (`nucleus-vm setup --windows-iso /path/to/Win11.iso`):

- Uses Packer with `src/vms/windows/packer.pkr.hcl` and QEMU builder.
- Requires a Windows 11 ISO path via `--windows-iso` **or** a `windowsIsoUrl` field in the `VMs.json` windows entry. When `windowsIsoUrl` is set, the ISO is downloaded automatically to `~/virtual machines/images/<name>-installer.iso` on first run (subsequent runs reuse the cache).
- On macOS/Linux, falls back from Mido to Fido URL resolver via `pwsh` (`Fido.ps1 -GetUrl`) + `curl`.
- On Windows, auto-detects WHPX accelerator when `tcg` is default; upgrades automatically. Pass `-Accelerator tcg` to suppress.
- SATA disk during build → VirtIO drivers installed post-install → final image is VirtIO-disk ready.
- Autounattend.xml bypasses TPM/Secure Boot checks, enables WinRM for Packer, and renders the managed guest account from the current host user identity.
- Apply the nucleus Windows guest config after first boot.

### Guest configuration status

Guest configuration is not automatic after first boot. `nucleus-vm setup` builds images and provisions VM runtimes; apply commands must be run inside each guest.

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
