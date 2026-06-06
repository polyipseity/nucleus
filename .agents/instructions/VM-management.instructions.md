---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm-setup.*, src/hosts/*/vms.nix, src/modules/VMs.json, src/modules/users.json, src/hosts/Windows/users.json, src/secrets/users-*.yml, tests/src/vm-setup-tests.nix, src/vms/**"
---

# VM Management

## Host × Guest Matrix

| Host \ Guest | macOS         | NixOS           | Windows         |
| ------------ | ------------- | --------------- | --------------- |
| macOS        | Tart (Packer) | UTM 4.x (QEMU)  | UTM 4.x (QEMU)  |
| NixOS        | not supported | libvirt/KVM     | libvirt/KVM     |
| Windows      | not supported | QEMU standalone | QEMU standalone |

macOS guest uses Tart (Apple Virtualization.framework) exclusively; automated
Tart→UTM runtime handoff is not supported (format mismatch, no tooling).

## Hostname Convention

VM guest OSes must use the same hostname and display name as the corresponding
host OS. The canonical values are:

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

## Guest Credential Convention

VM guest credentials must come from per-user SOPS secrets, not from the host
login name or any guessed/default password. This applies on every host OS
(macOS, NixOS, Windows) and every guest OS path (NixOS, Windows, macOS).

- Store the actual values in `src/secrets/users-<username>.yml`.
- Keep the keys flat and user-scoped by filename, for example:
  - `vm_guest_username`
  - `vm_guest_password`
- Reference those keys from:
  - `src/modules/users.json` on POSIX hosts
  - `src/hosts/Windows/users.json` on Windows hosts
- Use a `vmGuest` object with:
  - `usernameSecretKey`
  - `passwordSecretKey`

Required wiring and parity checks:

- POSIX flow: `scripts/vm-setup.sh` must resolve the current secret owner,
  read `src/modules/users.json`, decrypt `src/secrets/users-<username>.yml`,
  and pass the resolved credentials into every guest builder/template.
- Windows flow:
  `src/hosts/Windows/modules/system/Invoke-VMSetup.ps1` must resolve the same
  `vmGuest` references from `src/hosts/Windows/users.json`, decrypt the same
  per-user secret file, and pass the resolved credentials into every guest
  builder/template.
- NixOS guest paths: both `src/vms/nixos/guest.nix` and
  `src/vms/nixos/packer.pkr.hcl` must consume the injected credentials.
- Windows guest paths: `src/vms/windows/Autounattend.xml` placeholders and
  `src/vms/windows/packer.pkr.hcl` variables must stay in sync with runtime
  rendering.
- macOS guest path: `src/vms/macos/packer.pkr.hcl` must provision/update the guest
  account from the same resolved secret-backed values.
- Credential drift must invalidate stale VM artifacts on every supported build
  path so changing the secret-backed username or password actually rebuilds or
  refreshes the guest image/runtime instead of silently reusing stale disks.

When changing credential policy behavior, update
`tests/src/vm-setup-tests.nix` in the same commit.

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

## Disk Format

QCOW2 throughout all three platforms.
Stored at:

- macOS: `~/virtual machines/<name>.utm/Data/disk-main.qcow2`
- NixOS: `~/virtual machines/<name>.qcow2`
- Windows: `%USERPROFILE%\virtual machines\<name>.qcow2`

Pre-built images land in `~/virtual machines/images/<name>.qcow2`
(Windows: `%USERPROFILE%\virtual machines\images\<name>.qcow2`).
`nucleus-vm-setup` builds these images in phase 1 (if absent) and copies them to the disk location in phase 2.

QCOW2 enables copy-based migration between hosts without conversion.

## macOS — Tart (macOS guests)

- VM backend: Tart CLI (Apple Virtualization.framework); macOS host only.
- VM store: `~/virtual machines/.tart/vms/<name>/` — Tart's storage root
  (`~/.tart`) is symlinked to `~/virtual machines/.tart` by `nucleus-vm-setup`
  so Tart artifacts co-locate with UTM bundles for unified backup.
- Build tool: Packer + `tart-cli` plugin pulling
  `ghcr.io/cirruslabs/macos-<version>-base:latest` from GHCR.
- Start command (after build): `tart run <name>`.
- No UTM bundle is created for macOS guests; they remain Tart-managed.

## macOS — UTM

- VM backend: UTM 4.x QEMU backend.
- Bundle location: `~/virtual machines/<name>.utm/`
- Config template: `config.plist` pre-generated at
  `~/.local/share/nucleus/vms/<name>-config.plist` by `src/hosts/MacBook/vms.nix`
  at Home Manager activation time; `vm-setup.sh` copies it into the bundle.
- Disk pre-created in `Images/disk-main.qcow2` by copying the pre-built image from the images directory.
- After provisioning, UTM opens each bundle automatically.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: Shared (NAT) mode on all VMs.

- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.

## NixOS — libvirt/KVM

- VM infrastructure declared in `src/hosts/NixOS/vms.nix` (system module).
- Package: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd` in `environment.systemPackages`.
- User groups: `kvm` and `libvirtd` added to the managed user via `lib.mkAfter` in `vms.nix`.
- Domain XML pre-generated at `/etc/nucleus/vms/<name>-domain.xml` by `src/hosts/NixOS/vms.nix`
  at NixOS activation time; `vm-setup.sh` calls `virsh define` on the pre-generated file (idempotent).
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
- VirtioFS on Windows requires `virtiofsd` running as a separate process before the VM starts.
  See `~/virtual machines/README.md` for the exact command.

## Apply Hook

`nucleus-vm-setup` (and the `--vm-setup` flag for `nucleus apply`) is **opt-in**:

- POSIX: `src/scripts/apply.sh` passes `--vm-setup` to enable; skipped by default.
- Windows: `src/hosts/Windows/apply.ps1` uses `-VMSetup` switch; skipped by default.

The hook is always best-effort: a VM setup failure does not abort a completed system apply.

## Adding a New VM

1. Add an entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm-setup` on all three host platforms.
3. Add a test in `tests/src/vm-setup-tests.nix` if the new VM has platform-specific constraints.
4. Update `src/hosts/<platform>/MANUAL.md` if the VM requires manual steps.

## VM Image Building

`nucleus-vm-setup` is a two-phase command. Phase 1 builds QCOW2 OS images (if absent); phase 2 provisions VM bundles/domains from those images.

### Files

| File                                                  | Purpose                                                        |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `src/vms/nixos/guest.nix`                             | NixOS guest configuration for `nixos-generators` (macOS/NixOS) |
| `src/vms/nixos/packer.pkr.hcl`                        | Packer template for NixOS guest on Windows hosts               |
| `src/vms/windows/packer.pkr.hcl`                      | Packer template for Windows 11 guest on all hosts              |
| `src/vms/windows/Autounattend.xml`                    | Windows 11 answer file (unattended install, TPM bypass, WinRM) |
| `scripts/vm-setup.sh`                                 | Unified build+provision script for macOS and NixOS hosts       |
| `scripts/vm-setup.ps1`                                | Windows wrapper calling `Invoke-VMSetup.ps1`                   |
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

**Windows 11 guest (all hosts)** (`nucleus-vm-setup --windows-iso /path/to/Win11.iso`):

- Uses Packer with `src/vms/windows/packer.pkr.hcl` and QEMU builder.
- Requires a Windows 11 ISO path via `--windows-iso` **or** a `windowsIsoUrl` field in the `VMs.json`
  windows entry. When `windowsIsoUrl` is set, the ISO is downloaded automatically to
  `~/virtual machines/images/<name>-installer.iso` on first run (subsequent runs reuse the cache).
- On macOS/Linux hosts, when Mido fails, `vm-setup.sh` attempts a non-Windows
  Fido URL resolver fallback via `pwsh` (`Fido.ps1 -GetUrl`) and then downloads
  the resolved ISO URL with `curl`.
- On Windows hosts, `Invoke-VMSetup` auto-detects WHPX (Windows Hypervisor Platform) when the
  default `tcg` accelerator is in use. If WHPX is enabled, it upgrades automatically. If not,
  it warns and prints the command to enable it. Pass `-Accelerator tcg` explicitly to suppress.
- SATA disk during build → VirtIO drivers installed post-install → final image is VirtIO-disk ready.
- Autounattend.xml bypasses TPM/Secure Boot checks, enables WinRM for Packer,
  and renders the managed guest account from the current host user identity.
- Apply the nucleus Windows guest config after first boot.

### Guest configuration status

Guest configuration is not automatic after first boot. `nucleus-vm-setup` builds
images and provisions VM runtimes; apply commands must be run inside each guest.

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
