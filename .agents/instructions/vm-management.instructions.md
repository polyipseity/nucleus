---
description: "Use when adding or editing virtual machine provisioning across hosts, VM manifests, or VM test files."
name: "VM Management"
applyTo: "scripts/vm.*, scripts/vm-setup.*, src/scripts/lib/vm.sh, src/scripts/vms/**, src/hosts/*/vms.nix, src/modules/VMs.json, src/secrets/users-*.yml, tests/modules/vm-setup-tests.nix, src/vms/**, src/platforms/Windows/modules/system/Invoke-VMSetup.ps1, src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1"
---

# VM Management

## Host × Guest Matrix

| Host \ Guest | macOS         | NixOS           | Windows         |
| ------------ | ------------- | --------------- | --------------- |
| macOS        | Tart (Packer) | UTM 4.x (QEMU)  | UTM 4.x (QEMU)  |
| NixOS        | not supported | libvirt/KVM     | libvirt/KVM     |
| Windows      | not supported | QEMU standalone | QEMU standalone |

macOS guest uses Tart (Apple Virtualization.framework) exclusively; automated Tart→UTM runtime handoff is not supported (format mismatch, no tooling).

## Guest identity

SSOT: [`src/modules/VMs.json`](../../src/modules/VMs.json). This repo does not use `guestId`, `guestName`, or `osType`.

### Field contract

| Field | Manifest key | Use for | Never use for |
| ----- | ------------ | ------- | ------------- |
| Guest ID | `id` | CLI args (`nucleus-vm start NixOS`), `data/<id>.qcow2`, `<id>.vm.json`, `start-<id>.sh`, virsh/utm/tart domain name, UUID/MAC derivation, running-VM probes, GC keep sets | OS-family paths, build branching, display labels |
| Display name | `name` | UTM window title, libvirt `<title>`, CLI table human column, log labels (`-VmDisplay`) | File paths, CLI args, hypervisor domain name |
| OS type | `type` | `~/virtual machines/src/<type>/` runtime artifacts, `src/vms/<type>/` build templates, per-type GC, build branching, type-specific nested groups (`Android`, `Windows`, …) | Per-VM disk filenames, CLI selection, UUID derivation |
| Guest hostname | `hostname` | In-guest `hostName` / `ComputerName` via env/token plumbing; must equal `name` | Artifact paths or hypervisor names |

Provisioning host (`hosts[]`, `NUCLEUS_HOST`: `MacBook`, `NixOS`, `Windows`) is the physical machine running nucleus — not guest `type`.

### MacBook guest pattern

`id: MacBook`, `type: macOS`, `name: MacBook`, `hostname: MacBook`. The OS family is `macOS`; guest identity and display align with the host product name `MacBook`.

### Template tokens

| Token | Manifest field | Substituted into |
| ----- | -------------- | ---------------- |
| `__VM_ID__` | `id` | Hypervisor domain name, `.utm` bundle, `start-<id>.sh` paths, libvirt `<name>` |
| `__VM_DISPLAY__` | `name` | UTM `utmctl start` label, libvirt `<title>` |
| `__GUEST_HOSTNAME__` | `hostname` | Autounattend, Packer guest install |

### Naming conventions in code

- Locals/parameters holding manifest `id`: `vm_id`, `$vmId`, `-VmId` — not `vm_name` / `$vmName` / `-VmName`.
- Functions returning lists of manifest `id`: `vm_get_manifest_vm_ids`, `vm_get_expected_vm_ids`, `vm_get_running_ids`, `Get-VMRunningIdList`, `Get-VMRunningProcessNameList` — not `*names*`.
- Path helpers: `vm_descriptor_path VM_ID`, `vm_vm_json VM_ID`.

### Path layout

| Tree | Pattern | Driven by |
| ---- | ------- | --------- |
| Runtime VM dir | `~/virtual machines/src/<type>/` | manifest `type` |
| Repo build templates | `src/vms/<type>/` | manifest `type` (`NixOS`, `Windows`, `macOS`, …) |
| Per-guest disks | `~/virtual machines/data/<id>.qcow2` | manifest `id` |

`src/vms/templates/` is shared scaffolding — not a guest `type` directory.

## Hostname convention

VM guest OSes must use the same hostname as the corresponding host OS. The canonical values are declared in the `hostname` field of each entry in `src/modules/VMs.json` (identical to `name` for every VM today):

| Guest OS | `hostname` in VMs.json |
| -------- | ---------------------- |
| Android  | `Android`              |
| macOS    | `MacBook`              |
| NixOS    | `NixOS`                |
| Windows  | `Windows`              |

The manifest `hostname` is the single source of truth. Guest files consume it through env/var/token plumbing and must not hard-code a hostname:

- `src/vms/NixOS/guest.nix` — `networking.hostName = builtins.getEnv "NUCLEUS_VM_GUEST_HOSTNAME"` (and the flake attr `hostName`)
- `src/vms/NixOS/packer.pkr.hcl` — `guest_hostname` var rendered into `networking.hostName`
- `src/vms/macOS/packer.pkr.hcl` — `vm_hostname` var applied via `scutil` (HostName/ComputerName/LocalHostName)
- `src/vms/Windows/Autounattend.xml` — `<ComputerName>__GUEST_HOSTNAME__</ComputerName>`

When adding a VM, set `hostname` (and matching `name`) in `src/modules/VMs.json`; do not edit hostname literals in guest files.

## Guest credential convention

VM guest credentials must come from per-user SOPS secrets (`src/secrets/users-<username>.yml`), not from host login or defaults.

- Keys: `vm_guest_username`, `vm_guest_password` — referenced via `vmGuest` object (`usernameSecretKey`, `passwordSecretKey`) in `src/users/<username>/vm-guest.json`, assembled by `load-user-registry.sh` / `users-registry.nix`.
- Each setup script (`vm.sh` / `Invoke-VMSetup.ps1`) resolves the current user, reads the `vmGuest` reference, decrypts the secret, and passes credentials into guest builders/templates.
- All guest paths (NixOS: `guest.nix` + `packer.pkr.hcl`; Windows: `Autounattend.xml` + `packer.pkr.hcl`; macOS: `packer.pkr.hcl`) must consume injected credentials.
- Credential drift must invalidate stale VM artifacts so changing secret-backed values rebuilds rather than reusing stale disks.

Guest SSH public keys for NixOS `authorized_keys` are resolved from `src/modules/vm-guest-ssh-public-key-paths.json` (static `id_*.pub` paths first, then `ssh_personal_{username}.pub` templates aligned with `secrets.nix` and `50-nucleus.conf`). POSIX `vm_resolve_guest_ssh_public_key` in `src/scripts/lib/vm.sh` and Windows `Get-VMGuestSshPublicKey` read that manifest and export `NUCLEUS_VM_GUEST_SSH_PUBLIC_KEY` for `guest.nix`.

When changing credential policy, update `tests/modules/vm-setup-tests.nix` in the same commit.

## VM manifest

All virtual machines are declared in `src/modules/VMs.json`. This is the single source of truth for VM names, resources, and options consumed by all three platform setup scripts.

Required fields for each VM entry:

| Field              | Type    | Description                                                       |
| ------------------ | ------- | ----------------------------------------------------------------- |
| `id`               | string  | Machine-readable key used for files, domains, UUID/MAC derivation, and CLI selection |
| `name`             | string  | Human-readable label shown in UTM/virt-manager and CLI tables     |
| `type`             | string  | Guest OS family: `"Android"`, `"NixOS"`, `"Windows"`, `"macOS"` |
| `enabled`          | bool    | Whether the VM is provisioned                                     |
| `hosts`            | array   | Hosts that provision this VM (`"MacBook"`, `"NixOS"`, `"Windows"`); non-empty |
| `cpus`             | int     | Number of virtual CPUs                                            |
| `ram`             | string  | RAM as a suffixed size string per the size grammar (e.g. `"8GB"`) |
| `diskSize`        | string  | Boot disk size as a suffixed size string per the size grammar (e.g. `"128GB"`) |
| `shareDevDir`      | bool    | Mount `~/dev` inside the guest via VirtioFS                       |
| `sound`            | string  | Audio device: `"intel-hda"` or `"none"`                        |
| `portForwards`     | array   | Non-empty `{guestPort, hostPort}` port-forward pairs (see Port forwarding) |
| `hostname`         | string  | Guest OS hostname; must equal the `name` value (see Hostname convention) |
| `minImageSize`     | string  | Minimum prebuilt image size floor per the size grammar (e.g. `"4GB"`) |
| `macAddressPrefix` | string  | MAC address prefix used for the guest NIC                         |

Type-specific fields (nested objects keyed by `type`; all fields required when `type` matches, forbidden otherwise):

| `type`      | Group      | Fields                                                                                                                                                                                                                    |
| ----------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"Android"` | `Android`  | `systemImage`, `userdataImage`, `gsiImage`, `gsiUrl`, `gappsUrl` (all required; `gsiUrl` may be `null` for Lineage-only — no GSI disk; `gappsUrl` is the MindTheGapps zip URL for recovery sideload)                                                                                             |
| `"macOS"`  | `macOS`    | `version` (release name, e.g. `"tahoe"`)                                                                                                                                                                                 |
| `"Windows"` | `Windows`  | `edition` (e.g. `"pro"`), `isoUrl` (`null` = Mido/Fido auto-resolve; a URL auto-downloads the installer ISO when `--windows-iso` is omitted, cached at `~/virtual machines/src/Windows/installer.iso`)                  |

All common fields and every field in the matching type group are **required** — there are no optional manifest properties. Deliberate nullable values: `Windows.isoUrl` and `Android.gsiUrl` (`null` is valid; a URL is valid for both).

## Size suffix grammar

All size fields (`ram`, `diskSize`, `minImageSize`) are suffixed size strings matching the grammar below. The grammar is case-sensitive and identical across all three platform parsers (`src/modules/lib/size.nix`, `src/scripts/lib/size.sh`, `src/platforms/Windows/modules/SizeStrings.ps1`); a malformed string aborts provisioning with an error rather than coercing.

```
^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$
```

- **Decimal prefixes** `kB`, `MB`, `GB`, `TB` multiply by powers of 10 (×10³, ×10⁶, ×10⁹, ×10¹²).
- **Binary prefixes** `kiB`, `MiB`, `GiB`, `TiB` multiply by powers of 2 (×2¹⁰, ×2²⁰, ×2³⁰, ×2⁴⁰).
- A single optional space between the number and the prefix is allowed: `"8GB"`, `"8 GB"`, `"8192MiB"` are all valid.
- `KB` and `KiB` (capital `K`) are **invalid** and rejected. IEC/ISO spell the binary prefix `Ki`; this repo uses `kiB` for case-consistency — `k` is always lowercase and `K` is always invalid.
- Canonical manifest values use **decimal** prefixes (`"8GB"`, `"128GB"`); binary prefixes are accepted input but not the manifest convention.
- Property names carry no unit — the suffix string carries it (`ram`, `diskSize`, `minImageSize`; never `ramBytes`/`diskSizeBytes`).
- Canonical internal unit: integer bytes. Each parser returns the exact byte count; 1024-based math appears only inside the three parsers and the documented backend adapters (e.g. Packer's MiB `memory` adapter, Tart's whole-GiB conversion), never scattered through renderers.

## Port forwarding

Guest port forwards are declared in the `portForwards` array of each VM entry: non-empty `{guestPort, hostPort}` pairs mapping a guest port to a host port. All host-side forwards (UTM, QEMU `hostfwd`, Packer, Tart softnet-expose, libvirt passt) and guest-readiness probes are derived from this array — never hard-code host ports in production code.

**Reserved host port block:** `22000–22099` (nucleus VM forward range). Every `hostPort` must be unique across all VMs so concurrent guests do not collide.

| VM | Host port(s) | Guest port | Service |
|----|-------------|------------|---------|
| MacBook | `22010` | `22` | SSH |
| NixOS | `22020` | `22` | SSH |
| Windows | `22030` | `22` | SSH |
| Android | `22040` | `5555` | ADB |
| Android | `22041` | `5554` | Emulator console |

- Non-Android VMs declare exactly one `guestPort: 22` SSH entry. Android declares `guestPort: 5555` (ADB) and `guestPort: 5554` (emulator console) and must not declare `guestPort: 22`.
- UTM, QEMU/Packer, and libvirt render every `portForwards` entry generically (no per-type branching).
- QEMU/Packer: `hostfwd=tcp::<hostPort>-:<guestPort>` per entry.
- Guest-readiness probes resolve the manifest host port by `guestPort` (`22` for SSH, `5555` for ADB) — never by literal host port number.

| Backend | Forward mechanism | Host-local access |
|---------|-------------------|-------------------|
| UTM (Emulated) | `PortForward` plist dicts from manifest | `localhost:<hostPort>` |
| Windows QEMU | `hostfwd` in start scripts | `localhost:<hostPort>` |
| libvirt/KVM | passt `<portForward><range start='hostPort' to='guestPort'/></portForward>` | `localhost:<hostPort>` |
| Tart (macOS) | `--net-softnet-expose hostPort:guestPort` | Use `tart ip <name>` + SSH guest port `22` (softnet-expose does not bind loopback) |
| Android | Same as QEMU host backend | `adb connect localhost:<hostPort for guest 5555>` |

**Host tooling:** `adb` and `fastboot` are required for `nucleus-vm android-config`. POSIX hosts install them via `pkgs.android-tools` in `src/modules/core.nix` (`nucleus-apply`); the `nucleus-vm` flake app also bundles `android-tools` in its runtime inputs. Windows installs `Google.PlatformTools` via WinGet DSC (`src/hosts/Windows/system/packages.dsc.yml`).

## android-config cross-host parity

`android-config` is a paired native implementation — not bash delegation on Windows. See `cross-host-feature-parity.instructions.md` (What parity means).

| Layer | POSIX | Windows |
|-------|-------|---------|
| CLI entry | `scripts/vm.sh` → `do_android_config` | `scripts/vm.ps1` → `Invoke-AndroidConfig` |
| Implementation | `src/scripts/vms/android-config.sh` (+ magisk, fake-wifi) | `src/platforms/Windows/modules/system/Invoke-AndroidConfig.ps1` (+ `VMAndroid.ps1`) |
| Reset prerequisite | `scripts/vm.sh` `do_reset` | `Invoke-AndroidReset` in `Invoke-AndroidConfig.ps1` |

**Flags (both hosts):** `--gapps`, `--adb-keys`, `--magisk`, `--root`, `--fake-wifi`, `--fake-wifi-revert`. Omit all flags to print the manual.

**Privileged access policy:** Booted `android-config` uses Magisk `su` only (`adb shell su -c …`). Recovery `--adb-keys` uses the recovery shell when `id -u` is `0` (Advanced → Enable ADB). **`adb root` is never used.** `--root` sets `persist.sys.root_access=3` only; `ro.debuggable` must remain `0` on jqssun user builds. The Lineage **Rooted debugging** Developer-options toggle stays hidden on user builds — automation uses Magisk `su`, not host `adb root`.

**Change checklist:** update `VMs.json` + `VMs.schema.json`, `vm.sh`, `vm.ps1`, Windows modules, `tests/scripts/android-config-tests.sh`, `tests/scripts/android-config-tests.ps1`, `tests/integration/android-config-parity-tests.nix`, `tests/modules/vm-setup-tests.nix`, and all three `MANUAL.md` files in the same change.

**Platform exceptions (WHY):** MacBook UTM renderer prefs and freeze workarounds (`utm-android-freeze.instructions.md`); NixOS uses libvirt/KVM; Windows uses QEMU (`start-android-vm.ps1`). Recovery/booted workflow steps are shared; host-specific setup notes differ only in `MANUAL.md`.

## Disk format

QCOW2 throughout all three platforms. Runtime disks live under `data/`; per-type source payloads and pre-built goldens live under `src/<type>/`:

- macOS runtime: `~/virtual machines/data/<id>.qcow2` (UTM bundle exposes `~/virtual machines/<id>.utm/Data/disk-main.qcow2` as a hard link)
- NixOS runtime: `~/virtual machines/data/<id>.qcow2`
- Windows runtime: `%USERPROFILE%\virtual machines\data\<id>.qcow2`

Pre-built golden images land in `~/virtual machines/src/<type>/prebuilt image.qcow2` (Windows: `%USERPROFILE%\virtual machines\src\<type>\prebuilt image.qcow2`). `nucleus-vm setup` builds these in phase 1 (if absent) and copies them to `src/<type>/overlay backing.qcow2` before creating the `data/<id>.qcow2` overlay in phase 2.

QCOW2 enables copy-based migration between hosts without conversion.

## macOS — Tart (macOS guests)

- VM backend: Tart CLI (Apple Virtualization.framework); macOS host only.
- VM store: `~/virtual machines/tart/vms/<id>/` — Tart's storage root (`~/.tart`) is symlinked to `~/virtual machines/tart` by `nucleus-vm setup` so Tart artifacts co-locate with UTM bundles for unified backup.
- Build tool: Packer + `tart-cli` plugin pulling `ghcr.io/cirruslabs/macos-<version>-base:latest` from GHCR.
- Start command (after build): `tart run --net-softnet --net-softnet-expose <hostPort>:<guestPort> <id>` (rendered from manifest). Host-local SSH uses `tart ip <id>` + guest port `22`, not `localhost:<hostPort>`.
- No UTM bundle is created for macOS guests; they remain Tart-managed.
- **Running vs registered:** `tart list` (name column) and `vm_get_tart_registered_names` report catalog entries (local VMs and OCI images), including stopped ones. Running state uses `tart list --format json` and `.Running == true` via `vm_get_running_ids`.

## macOS — UTM

- VM backend: UTM 4.x QEMU backend.
- Bundle location: `~/virtual machines/<id>.utm/`
- Config template: `config.plist` pre-generated at `~/.local/share/nucleus/vms/<id>-config.plist` by `src/hosts/MacBook/vms.nix` at Home Manager activation time; `vm.sh setup` copies it into the bundle.
- Disk pre-created in `Images/disk-main.qcow2` by copying or linking from `src/<type>/` (system image for Android; overlay chain for non-Android).
- After provisioning, UTM opens each bundle automatically.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: **Emulated** (QEMU user/slirp) — required for `PortForward` to work; vmnet-shared silently drops forwards.

- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.
- **Running vs registered:** `utmctl list` (via `vm_get_utm_registered_names`) returns every registered VM regardless of `Status`. Running state filters `Status != stopped` (`starting`, `started`, `pausing`, `paused`, `resuming`, `stopping`) via `vm_get_running_ids`.

## Running state source of truth

`vm_get_running_ids` (POSIX) and `Get-VMRunningProcessNameList` (Windows) are the single probes for sync warnings, setup base-refresh skips, `list`/`status`, `pack`, and `resize` guards. Do not use registration helpers or unfiltered `utmctl list` / `tart list` name columns for running checks.

## NixOS — libvirt/KVM

- VM infrastructure declared in `src/hosts/NixOS/vms.nix` (system module).
- Package: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd`, `passt` in `environment.systemPackages`.
- User groups: `kvm` and `libvirtd` added to the managed user via `lib.mkAfter` in `vms.nix`.
- Domain XML pre-generated at `/etc/nucleus/vms/<name>-domain.xml` by `src/hosts/NixOS/vms.nix` at NixOS activation time; `vm.sh setup` calls `virsh define` on the pre-generated file (idempotent).
- Domain XML uses passt user-mode networking with `<portForward>` ranges derived from manifest `portForwards` (`start` = host port, `to` = guest port).
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

Post-apply VM behavior:

| Step | Default | Flag |
|------|---------|------|
| Config sync | **on** | `--no-vm-sync` / `-NoVMSync` to skip |
| Full provision | off | `--vm-setup` / `-VMSetup` (includes sync; do not run both) |

- POSIX: [`src/scripts/apply.sh`](src/scripts/apply.sh) runs `nucleus-vm sync` after rebuild unless `--no-vm-sync` is set.
- Windows: [`src/hosts/Windows/apply.ps1`](src/hosts/Windows/apply.ps1) runs `Invoke-VMSync` unless `-NoVMSync` is set.

Both hooks are best-effort: a VM sync/setup failure does not abort a completed system apply.

## Command taxonomy

| Command | When to use |
|---------|-------------|
| `sync` | Manifest or Nix VM template changed; VMs already provisioned. Runs automatically after apply. |
| `setup` | First VM, missing images/bundles, credential/config drift, new guest. Full provision (sync + build + disks). |
| `android-config` | Android only: sideload MindTheGapps in recovery (`--gapps`), install ADB keys in recovery or booted system (`--adb-keys`), install Magisk (`--magisk`, booted only), enable rooted debugging (`--root`, booted only; requires Magisk su), configure fake Wi‑Fi (`--fake-wifi`, booted only; requires Magisk su). Run without flags to print the manual. Recovery flow: **Enter fastboot** → `--gapps` → **Enable ADB** → sideload → reboot → boot system → **Allow USB debugging** → `--magisk` → `--root` → `--fake-wifi`. |
| `gc` | Remove stale VM artifacts not listed in `VMs.json`. Default preserves `data/` runtime disks; pass `--gc-data` to also GC orphaned overlays. Pass `--gc-disabled` to narrow the keep-set to enabled guests on the current host. |
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

| File                                                  | Purpose                                                        |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `src/vms/NixOS/guest.nix`                             | NixOS guest configuration for `nixos-generators` (macOS/NixOS) |
| `src/vms/NixOS/packer.pkr.hcl`                        | Packer template for NixOS guest on Windows hosts               |
| `src/vms/Windows/packer.pkr.hcl`                      | Packer template for Windows 11 guest on all hosts              |
| `src/vms/Windows/Autounattend.xml`                    | Windows 11 answer file (unattended install, TPM bypass, WinRM) |
| `scripts/vm.sh`                                       | Unified build+provision script for macOS and NixOS hosts       |
| `scripts/vm.ps1`                                      | Windows wrapper calling `Invoke-VMSetup.ps1`                   |
| `src/platforms/Windows/modules/system/Invoke-VMSetup.ps1` | Build + provision logic for Windows hosts                      |

### Build strategies

**NixOS guest on macOS/NixOS**:

- Uses `nix run github:nix-community/nixos-generators` to build from `src/vms/NixOS/guest.nix`.
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

## Removing a VM

1. Remove the entry from `src/modules/VMs.json`.
2. Manually delete the disk image and registration:
   - macOS: delete `<name>.utm` bundle from UTM document store.
   - NixOS: run `virsh undefine <name>` then delete `~/virtual machines/data/<name>.qcow2`.
   - Windows: delete `%USERPROFILE%\virtual machines\data\<name>.qcow2` and the start script.
