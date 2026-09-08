---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm.*, scripts/vm-setup.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/VMs.json, src/secrets/users-*.yml, tests/modules/vm-setup-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM Management

## Host × Guest Matrix

Full matrix and per-platform backend details (Tart, UTM, libvirt, QEMU) are in `vm-reference.reference.md`.

## Guest identity

Manifest: [`src/modules/VMs.json`](../../src/modules/VMs.json). This repo does not use `guestId`, `guestName`, or `osType`.

### Field contract

Key rules: `id` for file paths and CLI, `name` for display, `type` for build templates, `hostname` for in-guest identity (must equal `name`). Full field contract, template tokens, and path layout tables are in `vm-reference.reference.md`.

### MacBook guest pattern

`id: MacBook`, `type: macOS`, `name: MacBook`, `hostname: MacBook`. The OS family is `macOS`; guest identity and display align with the host product name `MacBook`.

### Naming conventions in code

- Locals/parameters holding manifest `id`: `vm_id`, `$vmId`, `-VmId` — not `vm_name` / `$vmName` / `-VmName`.
- Functions returning lists of manifest `id`: `vm_get_manifest_vm_ids`, `vm_get_expected_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList`, `Get-VMRunningProcessNameList` — not `*names*`.
- Path helpers: `vm_descriptor_path VM_ID`, `vm_vm_json VM_ID`.

## Hostname convention

VM guest OSes must use the same hostname as the corresponding host OS. The canonical values are declared in the `hostname` field of each entry in `src/modules/VMs.json` (identical to `name` for every VM today):

| Guest OS | `hostname` in VMs.json |
| -------- | ---------------------- |
| Android | `Android` |
| macOS | `MacBook` |
| NixOS | `NixOS` |
| Windows | `Windows` |

The manifest `hostname` is the canonical source. Guest files consume it through env/var/token plumbing and must not hard-code a hostname:

- `src/vms/guests/<id>/guest.nix` — `networking.hostName = builtins.getEnv "NUCLEUS_VM_GUEST_HOSTNAME"` (and the flake attr `hostName`)
- `src/vms/NixOS/packer.pkr.hcl` — `guest_hostname` var rendered into `networking.hostName`
- `src/vms/macOS/packer.pkr.hcl` — `vm_hostname` var applied via `scutil` (HostName/ComputerName/LocalHostName)
- `src/vms/Windows/Autounattend.xml` — `<ComputerName>__GUEST_HOSTNAME__</ComputerName>`

When adding a VM, set `hostname` (and matching `name`) in `src/modules/VMs.json`; do not edit hostname literals in guest files.

## Guest credential convention

VM guest credentials must come from per-user SOPS secrets (`src/secrets/users-<username>.yml`), not from host login or defaults.

- Keys: `vm_guest_username`, `vm_guest_password` — referenced via `vmGuest` object (`usernameSecretKey`, `passwordSecretKey`) in `src/users/<username>/vm-guest.json`, assembled by `load-user-registry.sh` / `users-registry.nix`.
- Each setup script (`vm.sh` / `Invoke-VMSetup.ps1`) resolves the current user, reads the `vmGuest` reference, decrypts the secret, and passes credentials into guest builders/templates.
- All guest paths (NixOS: `guests/<id>/guest.nix` + `packer.pkr.hcl`; Windows: `Autounattend.xml` + `packer.pkr.hcl`; macOS: `packer.pkr.hcl`) must consume injected credentials.
- Credential drift must invalidate stale VM artifacts so changing secret-backed values rebuilds rather than reusing stale disks.

Guest SSH public keys for NixOS `authorized_keys` are resolved from `src/modules/vm-guest-ssh-public-key-paths.json` (static `id_*.pub` paths first, then `ssh_personal_{username}.pub` templates aligned with `secrets.nix` and `50-nucleus.conf`). POSIX `vm_resolve_guest_ssh_public_key` in `src/scripts/lib/vm.sh` and Windows `Get-VMGuestSshPublicKey` read that manifest and export `NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY` for `guests/<id>/guest.nix`.

Update `tests/modules/vm-setup-tests.nix` in the same commit when changing credential policy.

## VM manifest

All virtual machines are declared in `src/modules/VMs.json`. Required fields, type-specific fields, and nullable value rules are in `vm-reference.reference.md`.

## Size suffix grammar

Size strings match `^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$` (case-sensitive). Decimal prefixes (kB–TB) for powers of 10; binary (kiB–TiB) for powers of 2. `KB`/`KiB` (capital K) are invalid. Full grammar and parser details are in `vm-reference.reference.md`.

## Port forwarding

Port forwards are declared per VM in `portForwards` (`{guestPort, hostPort}` pairs). Reserved block: `22000–22099`. Never hard-code host ports. Full port table, backend mechanisms, and host tooling details are in `vm-reference.reference.md`.

## android-config cross-host parity

`android-config` is a paired native implementation — not bash delegation on Windows. See `cross-host-feature-parity.instructions.md` (What parity means).

| Layer | POSIX | Windows |
| ------- | ------- | --------- |
| CLI entry | `scripts/vm.sh` → `do_android_config` | `scripts/vm.ps1` → `Invoke-AndroidConfig` |
| Implementation | `src/scripts/vms/android-config.sh` (+ magisk, fake-wifi) | `src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1` (+ `VMAndroid.ps1`) |
| Reset prerequisite | `scripts/vm.sh` `do_reset` | `Invoke-AndroidReset` in `Invoke-AndroidConfig.ps1` |

**Flags (both hosts):** `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`. Omit all flags to print the manual.

**Privileged access policy:** Booted `android-config` uses Magisk `su` only (`adb shell su -c …`). Recovery `--adb-keys` uses the recovery shell when `id -u` is `0` (Advanced → Enable ADB). **`adb root` is never used.** `--root` sets `persist.sys.root_access=3` only; `ro.debuggable` must remain `0` on user builds. The Lineage **Rooted debugging** Developer-options toggle stays hidden on user builds — automation uses Magisk `su`, not `adb root`.

**Change checklist:** update `VMs.json` + `VMs.schema.json`, `vm.sh`, `vm.ps1`, Windows modules, `tests/scripts/android-config-tests.sh`, `tests/scripts/android-config-tests.ps1`, `tests/integration/android-config-parity-tests.nix`, `tests/modules/vm-setup-tests.nix`, and all three `MANUAL.md` files in the same change.

**Platform exceptions (WHY):** MacBook UTM preferences and Android freeze workarounds (see [Android UTM freeze](#android-utm-freeze) below); NixOS uses libvirt/KVM; Windows uses QEMU (`start-android-vm.ps1`). Recovery/booted workflow steps are shared; host-specific setup notes differ only in `MANUAL.md`.

## Android UTM freeze

SPICE client (CocoaSpice) audio-pipeline deadlock: GStreamer teardown races CoreAudio IO thread, freezing all SPICE channels. Renderer-orthogonal — not display sleep, virgl, or guest-side.

**Workaround (repo-managed):** disable guest audio — `"sound": "none"` in `VMs.json`; `src/hosts/MacBook/vms.nix` renders empty Sound array. **Recovery:** quit UTM, relaunch, `nucleus-vm start Android` (only working recovery; RAM state lost, disk intact). **Diagnostics:** `sample <utm-pid> 5 -mayDie` for SPICE Main Loop in `playback_stop`; `adb devices` → `offline` confirms adbd wedge. Process: `qemu-aarch64-softmmu`. UTM #2221, #2364, #4781; CocoaSpice#5.

## Disk format

QCOW2 throughout all platforms. Runtime disks in `data/`, system images in `src/<type>/`. QCOW2 enables copy-based migration. Full disk layout, UEFI vars, and backing chain details are in `vm-reference.reference.md`.

## Per-platform backends

Full backend details (Tart, UTM, libvirt/KVM, QEMU via Scoop) are in `vm-reference.reference.md`.

## Running state source of truth

`vm_get_running_ids` (POSIX) and `Get-VMRunningProcessNameList` (Windows) are the single probes. Do not use registration helpers or unfiltered `utmctl list` / `tart list` for running checks.

## Apply hook

Post-apply VM behavior:

| Step | Default | Flag |
| ------ | --------- | ------ |
| Config sync | **on** | `--no-vm-sync` / `-NoVMSync` to skip |
| Full provision | off | `--vm-setup` / `-VMSetup` (includes sync; do not run both) |

- POSIX: [`src/scripts/apply.sh`](src/scripts/apply.sh) runs `nucleus-vm sync` after rebuild unless `--no-vm-sync` is set.
- Windows: [`src/hosts/Windows/apply.ps1`](src/hosts/Windows/apply.ps1) runs `Invoke-VMSync` unless `-NoVMSync` is set.

Both hooks are best-effort: a VM sync/setup failure does not abort a completed apply.

## Command taxonomy

| Command | When to use |
| --------- | ------------- |
| `sync` | Manifest or Nix VM template changed; VMs already provisioned. Runs automatically after apply. |
| `setup` | First VM, missing images/bundles, credential/config drift, new guest. Full provision (sync + build + disks). |
| `android-config` | Android only: sideload MindTheGapps in recovery (`--gapps`), install ADB keys in recovery or booted system (`--adb-keys`), install Magisk (`--magisk`, booted only), enable rooted debugging (`--root`, booted only; requires Magisk su), configure fake Wi‑Fi (`--fake-wifi`, booted only; requires Magisk su). Run without flags to print the manual. Recovery flow: **Enter fastboot** → `--gapps` → **Enable ADB** → sideload → reboot → boot system → **Allow USB debugging** → `--magisk` → `--root` → `--fake-wifi`. |
| `gc` | Remove stale VM artifacts not listed in `VMs.json`. Default preserves `data/` runtime disks; pass `--gc-data` to also GC orphaned data disks. Pass `--gc-disabled` to narrow the keep-set to enabled guests on the current host. |
| `pack` / `unpack` | Copy VM tree to another host (`unpack` may recreate UTM bundles). |
| `start` / `stop` | Runtime control. Restart after sync when port forwards changed. |

`sync` refreshes descriptors, start/stop scripts, UTM plists (with registration), and `virsh define`. It skips image build, disk creation, and GC.

## Adding a new VM

1. Add an entry to `src/modules/VMs.json` with all required fields.
2. Run `nucleus-vm setup` on all three host platforms.
3. Add a test in `tests/modules/vm-setup-tests.nix` if the new VM has platform-specific constraints.
4. Update `src/hosts/<platform>/MANUAL.md` if the VM requires manual steps.

## VM image building

`nucleus-vm setup` is a two-phase command. Phase 1 builds QCOW2 OS images (if absent); phase 2 provisions VM bundles/domains from those images.

### Files

| File | Purpose |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `src/vms/NixOS/base-guest.nix` | Identity-free NixOS guest base configuration for `nixos-generators` (macOS/NixOS) |
| `src/vms/guests/<id>/guest.nix` | Per-VM NixOS delta (hostname, credentials) applied at injection |
| `src/vms/NixOS/packer.pkr.hcl` | Packer template for NixOS guest on Windows hosts |
| `src/vms/Windows/packer.pkr.hcl` | Packer template for Windows 11 guest on all hosts |
| `src/vms/Windows/Autounattend.xml` | Windows 11 answer file (unattended install, TPM bypass, WinRM) |
| `scripts/vm.sh` | Combined build+provision script for macOS and NixOS hosts |
| `scripts/vm.ps1` | Windows wrapper calling `Invoke-VMSetup.ps1` |
| `src/platforms/Windows/modules/system/Invoke-VMSetup.ps1` | Build + provision logic for Windows hosts |

### Build strategies

**NixOS guest on macOS/NixOS**:

- Uses `nix run github:nix-community/nixos-generators` to build from `src/vms/NixOS/base-guest.nix`.
- Architecture-aware Btrfs formats: `qcow-efi-btrfs` (UEFI) on aarch64 hosts (UTM on Apple Silicon), `qcow-btrfs` (BIOS/hybrid) on x86_64. Format modules live in `src/vms/NixOS/formats/`. Both use `@`/`@nix` subvolumes and `compress-force=zstd` (shared with host via `src/hosts/NixOS/btrfs-options.nix`). Packer installs on Windows use the same layout.
- No Packer required; just `nix` command which is always present.

**NixOS guest on Windows**:

- Uses Packer with `src/vms/NixOS/packer.pkr.hcl` and QEMU builder.
- Downloads NixOS minimal ISO, boots via QEMU, sets root password, SSH-installs NixOS.
- `whpx` accelerator strongly recommended (Windows Hypervisor Platform); `tcg` works but is very slow.

**Windows 11 guest (all hosts)** (`nucleus-vm setup --windows-iso /path/to/Win11.iso`):

- Uses Packer with `src/vms/Windows/packer.pkr.hcl` and QEMU builder.
- Requires a Windows 11 ISO path via `--windows-iso` **or** a `Windows.isoUrl` field in the `VMs.json` `Windows` entry. When `Windows.isoUrl` is set, the ISO is downloaded automatically to `~/virtual machines/src/Windows/installer.iso` on first run (subsequent runs reuse the cache).
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
- Template authoring gotchas: `<<-EOT` heredocs inside `inline = [...]` arrays need a trailing comma after the `EOT` marker when more elements follow; a quoted delimiter (`<< 'EOT'`) disables shell expansion, leaving `${...}` literals in the generated file. `check-packer` `validate_dir` must supply a dummy `-var` for EVERY required packer variable or `packer validate` fails.

## Removing a VM

1. Remove the entry from `src/modules/VMs.json`.
2. Manually delete the disk image and registration:
   - macOS: delete `<name>.utm` bundle from UTM document store.
   - NixOS: run `virsh undefine <name>` then delete `~/virtual machines/data/<name>.qcow2`.
   - Windows: delete `%USERPROFILE%\virtual machines\data\<name>.qcow2` and the start script.
