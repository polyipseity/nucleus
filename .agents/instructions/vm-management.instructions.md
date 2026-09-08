---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm.*, scripts/vm-setup.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/VMs.json, src/secrets/users-*.yml, tests/modules/vm-setup-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM Management

## Guest identity

Manifest: `src/modules/VMs.json`. Not using `guestId`, `guestName`, or `osType`.

Key rules: `id` for file paths/CLI, `name` for display, `type` for build templates, `hostname` for in-guest identity (must equal `name`). Full field contract, tokens, path layout in `vm-reference.reference.md`.

MacBook: `id: MacBook`, `type: macOS`, `name: MacBook`, `hostname: MacBook`.

### Naming conventions

- Locals/params holding `id`: `vm_id`, `$vmId`, `-VmId` — not `vm_name`.
- Functions returning id lists: `vm_get_manifest_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList` — not `*names*`.

## Hostname convention

Guest OSes use the same hostname as the corresponding host. Canonical values from `hostname` field in `VMs.json`:

| Guest OS | `hostname` in VMs.json |
| -------- | ---------------------- |
| Android | `Android` |
| macOS | `MacBook` |
| NixOS | `NixOS` |
| Windows | `Windows` |

Manifest `hostname` is canonical. Guest files consume it via env/token plumbing — never hard-code hostnames:

- `src/vms/guests/<id>/guest.nix`: `networking.hostName = builtins.getEnv "NUCLEUS_VM_GUEST_HOSTNAME"`
- `src/vms/NixOS/packer.pkr.hcl`: `guest_hostname` var
- `src/vms/macOS/packer.pkr.hcl`: `vm_hostname` var via `scutil`
- `src/vms/Windows/Autounattend.xml`: `__GUEST_HOSTNAME__` token

Set `hostname` (matching `name`) in `VMs.json`; never edit hostname literals in guest files.

## Guest credentials

From per-user SOPS secrets (`src/secrets/users-<username>.yml`), never host login. Keys: `vm_guest_username`, `vm_guest_password` via `vmGuest` object in user registry. Setup scripts decrypt and inject. Credential drift must invalidate stale artifacts.

SSH public keys for NixOS `authorized_keys`: `src/modules/vm-guest-ssh-public-key-paths.json`. Update `tests/modules/vm-setup-tests.nix` when changing credential policy.



## android-config

Paired native implementations (not bash on Windows):

| Layer | POSIX | Windows |
| ------- | ------- | --------- |
| CLI | `vm.sh` → `do_android_config` | `vm.ps1` → `Invoke-AndroidConfig` |
| Impl | `src/scripts/vms/android-config.sh` | `Invoke-AndroidConfig.ps1` + `VMAndroid.ps1` |

**Flags:** `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`. No flags = manual.

**Privileged access:** Magisk `su` only. **Never `adb root`.** `--root` sets `persist.sys.root_access=3`; `ro.debuggable` stays `0`.

**Change checklist:** `VMs.json` + `VMs.schema.json`, `vm.sh`, `vm.ps1`, Windows modules, `tests/scripts/android-config-tests.{sh,ps1}`, `tests/integration/android-config-parity-tests.nix`, `tests/modules/vm-setup-tests.nix`, all `MANUAL.md`.

## Android UTM freeze

CocoaSpice audio-pipeline deadlock: GStreamer teardown races CoreAudio IO thread. Not display sleep, virgl, or guest-side.

**Workaround:** disable guest audio (`"sound": "none"` in `VMs.json`). **Recovery:** quit UTM, relaunch, `nucleus-vm start Android`. **Diagnostics:** `sample <utm-pid> 5 -mayDie`; `adb devices` → `offline` confirms adbd wedge. UTM #2221, #2364, #4781; CocoaSpice#5.



## Running state

`vm_get_running_ids` (POSIX) and `Get-VMRunningProcessNameList` (Windows) are the only probes. Never registration helpers or unfiltered `utmctl list`/`tart list`.

## Apply hook

| Step | Default | Flag |
| ------ | --------- | ------ |
| Config sync | **on** | `--no-vm-sync` / `-NoVMSync` |
| Full provision | off | `--vm-setup` / `-VMSetup` (includes sync; do not run both) |

POSIX `apply.sh` runs `nucleus-vm sync` unless `--no-vm-sync`. Windows `apply.ps1` runs `Invoke-VMSync` unless `-NoVMSync`. Both best-effort — failure does not abort apply.

## Command taxonomy

| Command | Use when |
| --------- | ------------- |
| `sync` | Manifest/template changed; VMs already provisioned. Runs automatically after apply. |
| `setup` | First VM, missing images, credential drift, new guest. Full provision. |
| `android-config` | Android only: `--gapps`/`--adb-keys`/`--magisk`/`--root`/`--fake-wifi`/`--fake-wifi-revert`. No flags = manual. Recovery flow: **fastboot** → `--gapps` → **Enable ADB** → sideload → reboot → **Allow USB debugging** → `--magisk` → `--root` → `--fake-wifi`. |
| `gc` | Remove stale artifacts. `--gc-data` includes orphaned data disks. `--gc-disabled` narrows to enabled guests. |
| `pack`/`unpack` | Copy VM tree to another host. |
| `start`/`stop` | Runtime control. Restart after sync when port forwards changed. |

`sync` refreshes descriptors, start/stop scripts, UTM plists, `virsh define`. Skips image build, disk creation, GC.

## Adding a new VM

1. Add entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm setup` on all host platforms.
3. Add test in `tests/modules/vm-setup-tests.nix` if platform-specific constraints exist.
4. Update `src/hosts/<platform>/MANUAL.md` if manual steps required.

## VM image building

Two-phase: phase 1 builds QCOW2 OS images (if absent); phase 2 provisions bundles/domains.

### Files

| File | Purpose |
| --- | --- |
| `src/vms/NixOS/base-guest.nix` | NixOS guest base for `nixos-generators` (macOS/NixOS) |
| `src/vms/guests/<id>/guest.nix` | Per-VM NixOS delta (hostname, credentials) |
| `src/vms/NixOS/packer.pkr.hcl` | NixOS Packer template (Windows hosts) |
| `src/vms/Windows/packer.pkr.hcl` | Windows 11 Packer template (all hosts) |
| `src/vms/Windows/Autounattend.xml` | Windows 11 answer file (TPM bypass, WinRM) |
| `scripts/vm.sh` | Build+provision (macOS/NixOS) |
| `scripts/vm.ps1` | Windows wrapper → `Invoke-VMSetup.ps1` |
| `src/platforms/Windows/modules/system/Invoke-VMSetup.ps1` | Windows build+provision logic |

### Build strategies

**NixOS on macOS/NixOS**: `nixos-generators` from `base-guest.nix`. Btrfs formats: `qcow-efi-btrfs` (aarch64) or `qcow-btrfs` (x86_64). No Packer.

**NixOS on Windows**: Packer + QEMU. Downloads ISO, SSH-installs. `whpx` recommended.

**Windows 11** (`--windows-iso /path/to/Win11.iso`):
- Packer + QEMU. ISO via `--windows-iso` or `Windows.isoUrl` in `VMs.json` (auto-downloads).
- Mido→Fido fallback on POSIX. WHPX auto-detect on Windows.
- SATA→VirtIO. Autounattend bypasses TPM/Secure Boot. Guest config applied after first boot.

### Packer requirements

- Packer: `pkgs.packer` (POSIX) / `HashiCorp.Packer` (Windows). QEMU: `pkgs.qemu` (POSIX) / Scoop.
- Windows builds: `winrm_timeout = "3h"` (30–90 min).
- Gotchas: trailing comma after `<<-EOT` in `inline = [...]`; quoted `<< 'EOT'` disables expansion; `check-packer` needs dummy `-var` for every required variable.

## Removing a VM

1. Remove entry from `src/modules/VMs.json`.
2. Delete disk and registration: macOS delete `.utm` bundle; NixOS `virsh undefine` + delete `.qcow2`; Windows delete `.qcow2` + start script.
