---
description: "Use when editing VM CLI, manifest consumers, template tokens, or scripts that reference guest id, name, type, or hostname."
name: "VM Guest Identity"
applyTo: "scripts/vm.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/VMs.json, src/vms/**, tests/modules/vm-setup-tests.nix, src/hosts/Windows/modules/system/Invoke-VMSetup.ps1, src/hosts/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM guest identity (id, name, type, hostname)

SSOT: [`src/modules/VMs.json`](../../src/modules/VMs.json). This repo does not use `guestId`, `guestName`, or `osType`.

## Field contract

| Field | Manifest key | Use for | Never use for |
| ----- | ------------ | ------- | ------------- |
| Guest ID | `id` | CLI args (`nucleus-vm start NixOS`), `data/<id>.qcow2`, `<id>.vm.json`, `start-<id>.sh`, virsh/utm/tart domain name, UUID/MAC derivation, running-VM probes, GC keep sets | OS-family paths, build branching, display labels |
| Display name | `name` | UTM window title, libvirt `<title>`, CLI table human column, log labels (`-VmDisplay`) | File paths, CLI args, hypervisor domain name |
| OS type | `type` | `~/virtual machines/src/<type>/` runtime artifacts, `src/vms/<type>/` build templates, per-type GC, build branching, type-specific nested groups (`Android`, `Windows`, …) | Per-VM disk filenames, CLI selection, UUID derivation |
| Guest hostname | `hostname` | In-guest `hostName` / `ComputerName` via env/token plumbing; must equal `name` | Artifact paths or hypervisor names |

Provisioning host (`hosts[]`, `NUCLEUS_HOST`: `MacBook`, `NixOS`, `Windows`) is the physical machine running nucleus — not guest `type`.

## MacBook guest pattern

`id: MacBook`, `type: macOS`, `name: MacBook`, `hostname: MacBook`. The OS family is `macOS`; guest identity and display align with the host product name `MacBook`.

## Template tokens

| Token | Manifest field | Substituted into |
| ----- | -------------- | ---------------- |
| `__VM_ID__` | `id` | Hypervisor domain name, `.utm` bundle, `start-<id>.sh` paths, libvirt `<name>` |
| `__VM_DISPLAY__` | `name` | UTM `utmctl start` label, libvirt `<title>` |
| `__GUEST_HOSTNAME__` | `hostname` | Autounattend, Packer guest install |

## Naming conventions in code

- Locals/parameters holding manifest `id`: `vm_id`, `$vmId`, `-VmId` — not `vm_name` / `$vmName` / `-VmName`.
- Functions returning lists of manifest `id`: `vm_get_manifest_vm_ids`, `vm_get_expected_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIds` — not `*names*`.
- Path helpers: `vm_descriptor_path VM_ID`, `vm_vm_json VM_ID`.

## Path layout

| Tree | Pattern | Driven by |
| ---- | ------- | --------- |
| Runtime VM dir | `~/virtual machines/src/<type>/` | manifest `type` |
| Repo build templates | `src/vms/<type>/` | manifest `type` (`NixOS`, `Windows`, `macOS`, …) |
| Per-guest disks | `~/virtual machines/data/<id>.qcow2` | manifest `id` |

`src/vms/templates/` is shared scaffolding — not a guest `type` directory.

## Related instructions

- Operational VM workflow: [`vm-management.instructions.md`](vm-management.instructions.md)
- Host vs guest filesystem: [`host-filesystem-scope.instructions.md`](host-filesystem-scope.instructions.md)
