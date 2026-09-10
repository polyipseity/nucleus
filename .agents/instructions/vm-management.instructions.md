---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm.*, scripts/vm-setup.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/vms/**, src/secrets/users-*.yml, tests/modules/vm-setup-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
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

Guest OSes match host hostnames. Values from `hostname` in `VMs.json`: Android→`Android`, macOS→`MacBook`, NixOS→`NixOS`, Windows→`Windows`. Set in `VMs.json` (matching `name`); never edit literals in guest files. Guest files consume via `NUCLEUS_VM_GUEST_HOSTNAME` env (NixOS), `guest_hostname` var (Packer), `vm_hostname` var (macOS), `__GUEST_HOSTNAME__` token (Windows Autounattend).

## Guest credentials

From per-user SOPS secrets, never host login. Keys: `vm_guest_username`, `vm_guest_password` via `vmGuest` in user registry. Setup scripts decrypt and inject. Drift must invalidate stale artifacts. SSH keys: `src/modules/vm-guest-ssh-public-key-paths.json`. Update `tests/modules/vm-setup-tests.nix` when changing.



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

CocoaSpice deadlock: GStreamer teardown races CoreAudio. **Workaround:** `"sound": "none"` in `VMs.json`. **Recovery:** quit UTM, relaunch, `nucleus-vm start Android`. **Diag:** `sample <utm-pid> 5 -mayDie`; `adb devices`→`offline`. UTM #2221, #2364, #4781; CocoaSpice#5.



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
| --- | --- |
| `sync` | Manifest changed; VMs provisioned. Auto after apply. |
| `setup` | First VM, missing images, drift, new guest. Full provision. |
| `android-config` | Android: `--gapps`/`--adb-keys`/`--magisk`/`--root`/`--fake-wifi`/`--fake-wifi-revert`. Manual: fastboot→`--gapps`→Enable ADB→sideload→reboot→Allow debugging→`--magisk`→`--root`→`--fake-wifi`. |
| `gc` | Stale artifacts. `--gc-data`: orphaned disks. `--gc-disabled`: enabled guests only. |
| `pack`/`unpack` | Copy VM tree to another host. |
| `start`/`stop` | Runtime. Restart after sync when ports changed. |

`sync` refreshes descriptors, scripts, UTM plists, `virsh define`. Skips build/GC.

## Adding a new VM

1. Add entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm setup` on all host platforms.
3. Add test in `tests/modules/vm-setup-tests.nix` if platform-specific constraints exist.
4. Update `src/hosts/<platform>/MANUAL.md` if manual steps required.

## VM image building

Two-phase: phase 1 builds QCOW2 OS images (if absent); phase 2 provisions bundles/domains.

### Files

`base-guest.nix` (NixOS base), `guests/<id>/guest.nix` (per-VM delta), `NixOS/packer.pkr.hcl` (NixOS on Windows), `Windows/packer.pkr.hcl` (Win11 all hosts), `Windows/Autounattend.xml` (TPM bypass/WinRM), `scripts/vm.sh` (POSIX build+provision), `scripts/vm.ps1` (Windows wrapper), `Invoke-VMSetup.ps1` (Windows logic).

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
