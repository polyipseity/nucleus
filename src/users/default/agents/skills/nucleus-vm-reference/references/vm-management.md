---
description: "Use when adding or editing VM provisioning, manifests, or VM tests."
name: "VM Management"
applyTo: "scripts/vm.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/vms/**, src/secrets/users/*.yml, tests/modules/vm-setup-manifest-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM management

Manifest: `src/modules/vms/VMs.json`. Field contracts, tokens, paths, host/guest matrices, ports, and backend detail live in `src/users/default/agents/skills/nucleus-vm-reference/references/vm-reference.md`.

Locals and parameters holding an id are `vm_id`, `$vmId`, `-VmId`, never `vm_name`. Functions returning id lists are `vm_get_manifest_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList`, never `*names*`.

Guest hostnames match host names and come from `hostname` in `VMs.json` (equal to `name`). Never edit literals: NixOS reads `NUCLEUS_VM_GUEST_HOSTNAME`, Packer `guest_hostname`, macOS `vm_hostname`, Windows Autounattend `__GUEST_HOSTNAME__`.

Guest credentials come from per-user SOPS secrets, never the host login: `vm_guest_username` and `vm_guest_password` via `vmGuest` in the user registry, SSH keys in `src/modules/vms/vm-guest-ssh-public-key-paths.json`. Setup decrypts and injects; drift invalidates stale artifacts. Update `tests/modules/vm-setup-manifest-tests.nix` on any change.

## android-config

POSIX: `vm.sh` → `do_android_config`, implemented in `src/scripts/vms/android-config.sh`. Windows: `vm.ps1` → `Invoke-AndroidConfig`, implemented in `Invoke-AndroidConfig.ps1` and `VMAndroid.ps1`. Flags: `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`; no flags means manual path. Privileged access uses Magisk `su`, never `adb root`. `--root` sets `persist.sys.root_access=3` and leaves `ro.debuggable` at `0`.

A change touches `VMs.json` + `VMs.schema.json`, `vm.sh`, `vm.ps1`, the Windows modules, `tests/scripts/android-config-tests.{sh,ps1}`, `tests/platforms/Windows/modules/embedded-content/android-config-parity.Tests.ps1`, `tests/modules/vm-setup-manifest-tests.nix`, and every `MANUAL.md`.

Android UTM freeze: CocoaSpice GStreamer teardown races CoreAudio, so `sound` is `none` in `VMs.json`. Recover by quitting UTM and running `nucleus-vm start Android`. Diagnose with `sample <utm-pid> 5 -mayDie` and `adb devices` reporting `offline` (UTM #2221, #2364, #4781; CocoaSpice #5).

Running state comes only from `vm_get_running_ids` (POSIX) and `Get-VMRunningProcessNameList` (Windows); never a registration helper, unfiltered `utmctl list`, or `tart list`.

## Apply hook and commands

Config sync is on by default (`--no-vm-sync` / `-NoVMSync`). Full provision is off (`--vm-setup` / `-VMSetup`, includes sync; do not run both). Both paths treat failure as best-effort without aborting apply.

`sync` follows manifest changes on provisioned VMs and refreshes descriptors, scripts, UTM plists, and `virsh define`, never builds or GCs. `setup` handles first VM, missing images, drift, or new guest. `android-config` takes the flags above or the manual sequence: fastboot, `--gapps`, Enable ADB, sideload, reboot, Allow debugging, `--magisk`, `--root`, `--fake-wifi`. `gc` clears stale artifacts (`--gc-data` for orphaned disks, `--gc-disabled` for enabled guests only). `pack`/`unpack` copies a tree to another host. `start`/`stop` handles runtime; restart after sync when ports changed.

Adding a VM: add the full `VMs.json` entry, run `nucleus-vm setup` on each host platform, add a `tests/modules/vm-setup-manifest-tests.nix` case for platform constraints, and update `src/hosts/<platform>/MANUAL.md` when manual steps remain. Removing one: delete the `VMs.json` entry, then the disk and registration (`.utm` bundle on macOS, `virsh undefine` plus `.qcow2` on NixOS, `.qcow2` and start script on Windows).

## Image building

Build QCOW2 OS images if absent, then provision bundles and domains. Files: `base-guest.nix`, `guests/<id>/guest.nix`, `NixOS/packer.pkr.hcl`, `Windows/packer.pkr.hcl`, `Windows/Autounattend.xml` (TPM bypass, WinRM), `scripts/vm.sh`, `scripts/vm.ps1`, and `Invoke-VMSetup.ps1`.

NixOS on macOS or NixOS uses `nixos-generators` from `base-guest.nix`, no Packer; formats `qcow-efi-btrfs` (aarch64) and `qcow-btrfs` (x86_64). NixOS on Windows uses Packer plus QEMU, downloading the ISO and installing over SSH, preferring `whpx`. Windows 11 (`--windows-iso /path/to/Win11.iso`) uses Packer plus QEMU, the flag path or `Windows.isoUrl`, Mido to Fido fallback on POSIX, WHPX auto-detection on Windows, and SATA switched to VirtIO; Autounattend bypasses TPM and Secure Boot and guest config lands after first boot.

Packer is `pkgs.packer` on POSIX and `HashiCorp.Packer` on Windows; QEMU is `pkgs.qemu` on POSIX and Scoop on Windows. Windows builds need `winrm_timeout = "3h"` (30 to 90 min). Gotchas: trailing comma after `<<-EOT` in `inline = [...]`, quoted `<< 'EOT'` disables expansion, and `check-packer` needs a dummy `-var` for every required variable.
