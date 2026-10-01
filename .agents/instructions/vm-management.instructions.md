---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/vms/**, src/secrets/users/*.yml, tests/modules/vm-setup-manifest-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM management

## Guest identity

Manifest: `src/modules/vms/VMs.json`. Field contract, tokens, and path layout live in `vm-reference.reference.md`.

Locals and parameters holding an id are `vm_id`, `$vmId`, `-VmId`, never `vm_name`. Functions returning id lists are `vm_get_manifest_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList`, never `*names*`.

## Hostname convention

Guest OSes match host hostnames, and the value comes from `hostname` in `VMs.json` (which must equal `name`). Never edit the literal in a guest file: NixOS reads `NUCLEUS_VM_GUEST_HOSTNAME`, Packer `guest_hostname`, macOS `vm_hostname`, and Windows Autounattend the `__GUEST_HOSTNAME__` token.

## Guest credentials

From per-user SOPS secrets, never the host login: `vm_guest_username` and `vm_guest_password` via `vmGuest` in the user registry, with SSH keys in `src/modules/vm-guest-ssh-public-key-paths.json`. Setup scripts decrypt and inject, so drift must invalidate stale artifacts. Update `tests/modules/vm-setup-manifest-tests.nix` when any of this changes.

## android-config

| Layer | POSIX | Windows |
| ------- | ------- | --------- |
| CLI | `vm.sh` → `do_android_config` | `vm.ps1` → `Invoke-AndroidConfig` |
| Impl | `src/scripts/vms/android-config.sh` | `Invoke-AndroidConfig.ps1` + `VMAndroid.ps1` |

Flags: `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`. No flags means the manual path.

Privileged access goes through Magisk `su` only, never `adb root`. `--root` sets `persist.sys.root_access=3` and leaves `ro.debuggable` at `0`.

A change touches `VMs.json` + `VMs.schema.json`, `vm.sh`, `vm.ps1`, the Windows modules, `tests/scripts/android-config-tests.{sh,ps1}`, `tests/integration/android-config-parity-tests.nix`, `tests/modules/vm-setup-manifest-tests.nix`, and every `MANUAL.md`.

## Android UTM freeze

CocoaSpice deadlock: GStreamer teardown races CoreAudio, so `sound` is `none` for Android in `VMs.json`. Recover by quitting UTM and running `nucleus-vm start Android`. Diagnose with `sample <utm-pid> 5 -mayDie` and an `adb devices` that reports `offline` (UTM #2221, #2364, #4781; CocoaSpice #5).

## Running state

`vm_get_running_ids` (POSIX) and `Get-VMRunningProcessNameList` (Windows) are the only probes. Never a registration helper, never an unfiltered `utmctl list` or `tart list`.

## Apply hook

| Step | Default | Flag |
| ------ | --------- | ------ |
| Config sync | on | `--no-vm-sync` / `-NoVMSync` |
| Full provision | off | `--vm-setup` / `-VMSetup` (includes sync; do not run both) |

Both apply paths treat a failure here as best-effort: it does not abort apply.

## Command taxonomy

| Command | Use when |
| --- | --- |
| `sync` | Manifest changed and VMs are provisioned. Runs after apply. |
| `setup` | First VM, missing images, drift, new guest. |
| `android-config` | Android flags above, or the manual sequence fastboot → `--gapps` → Enable ADB → sideload → reboot → Allow debugging → `--magisk` → `--root` → `--fake-wifi`. |
| `gc` | Stale artifacts. `--gc-data` for orphaned disks, `--gc-disabled` for enabled guests only. |
| `pack`/`unpack` | Copy a VM tree to another host. |
| `start`/`stop` | Runtime. Restart after sync when ports changed. |

`sync` refreshes descriptors, scripts, UTM plists, and `virsh define`; it never builds or GCs.

## Adding a VM

Add the `VMs.json` entry with every required field, run `nucleus-vm setup` on each host platform, add a `tests/modules/vm-setup-manifest-tests.nix` case for any platform-specific constraint, and update `src/hosts/<platform>/MANUAL.md` when manual steps remain.

## Removing a VM

Delete the `VMs.json` entry, then the disk and registration: the `.utm` bundle on macOS, `virsh undefine` plus the `.qcow2` on NixOS, the `.qcow2` and start script on Windows.

## VM image building

Two phases: build the QCOW2 OS images if absent, then provision bundles and domains.

Files: `base-guest.nix` (NixOS base), `guests/<id>/guest.nix` (per-VM delta), `NixOS/packer.pkr.hcl` (NixOS on Windows), `Windows/packer.pkr.hcl` (Win11 on all hosts), `Windows/Autounattend.xml` (TPM bypass, WinRM), `scripts/vm.sh` (POSIX build and provision), `scripts/vm.ps1` (Windows wrapper), `Invoke-VMSetup.ps1` (Windows logic).

- NixOS on macOS or NixOS: `nixos-generators` from `base-guest.nix`, no Packer. Btrfs formats are `qcow-efi-btrfs` (aarch64) and `qcow-btrfs` (x86_64).
- NixOS on Windows: Packer plus QEMU, downloading the ISO and installing over SSH. Prefer `whpx`.
- Windows 11 (`--windows-iso /path/to/Win11.iso`): Packer plus QEMU, the ISO from the flag or `Windows.isoUrl` in `VMs.json`, Mido to Fido fallback on POSIX, WHPX auto-detected on Windows, SATA switched to VirtIO. The Autounattend bypasses TPM and Secure Boot, and the guest config lands after first boot.

Packer is `pkgs.packer` on POSIX and `HashiCorp.Packer` on Windows, QEMU is `pkgs.qemu` on POSIX and Scoop on Windows. Windows builds need `winrm_timeout = "3h"` (30 to 90 min). Gotchas: a trailing comma after `<<-EOT` in `inline = [...]`, a quoted `<< 'EOT'` disables expansion, and `check-packer` needs a dummy `-var` for every required variable.
