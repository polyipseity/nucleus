---
description: "Use when adding or editing VM provisioning, manifests, or VM tests."
name: "VM Management"
applyTo: "scripts/vm.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/vms/**, src/secrets/users/*.yml, tests/modules/vm-setup-manifest-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM management

Manifest: `src/modules/vms/VMs.json`. Field contracts, host-guest matrix, ports, paths, size grammar, and backend detail live in `.agents/skills/nucleus-vm-reference/references/vm-reference.md`; workflow detail lives in `vm-management.md` in that same references directory.

Ids use `vm_id`, `$vmId`, `-VmId`, never `vm_name`; id-list functions are `vm_get_manifest_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList`. Guest hostname comes from `hostname` (equal to `name`), never a literal: NixOS `NUCLEUS_VM_GUEST_HOSTNAME`, Packer `guest_hostname`, macOS `vm_hostname`, Windows `__GUEST_HOSTNAME__`. Credentials come from per-user SOPS and `vmGuest`, SSH keys from `vm-guest-ssh-public-key-paths.json`; update `vm-setup-manifest-tests.nix` on change.

android-config flags are `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`; privilege uses Magisk `su`, never `adb root`, and `--root` sets `persist.sys.root_access=3` with `ro.debuggable=0`. Android UTM freezes on CocoaSpice teardown, so `sound` is `none`; recover with `nucleus-vm start Android`. Running probes are only `vm_get_running_ids` and `Get-VMRunningProcessNameList`.

Defaults: config sync on (`--no-vm-sync`), full provision off (`--vm-setup`, includes sync, best-effort failure). Use `sync`, `setup`, `android-config`, `gc`, `pack`/`unpack`, and `start`/`stop` as defined in the reference. Image builds use base guest plus per-VM delta and Packer for Windows guests, with `winrm_timeout = "3h"`.
