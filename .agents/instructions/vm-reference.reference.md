---
description: "Reference: VM host×guest matrix, manifest schema, size grammar, port forwarding, disk format, and per-platform backend details. Read on demand when adding/modifying VMs or debugging platform-specific behavior."
name: "VM Reference"
---

# VM reference

## Host × Guest Matrix

| Host \ Guest | macOS | NixOS | Windows |
| ------------ | ------------- | --------------- | --------------- |
| macOS | Tart (Packer) | UTM 4.x (QEMU) | UTM 4.x (QEMU) |
| NixOS | not supported | libvirt/KVM | libvirt/KVM |
| Windows | not supported | QEMU standalone | QEMU standalone |

macOS guest uses Tart (Apple Virtualization.framework) exclusively; automated Tart→UTM runtime handoff is not supported (format mismatch, no tooling).

## Guest identity — field contract

| Field | Manifest key | Use for | Never use for |
| ----- | ------------ | ------- | ------------- |
| Guest ID | `id` | CLI args (`nucleus-vm start NixOS`), `data/<id>.qcow2`, `<id>.vm.json`, `start-<id>.sh`, virsh/utm/tart domain name, UUID/MAC derivation, running-VM probes, GC keep sets | OS-family paths, build branching, display labels |
| Display name | `name` | UTM window title, libvirt `<title>`, CLI table human column, log labels (`-VmDisplay`) | File paths, CLI args, hypervisor domain name |
| OS type | `type` | `~/virtual machines/src/<type>/` runtime artifacts, `src/vms/<type>/` build templates, per-type GC, build branching, type-specific nested groups (`Android`, `Windows`, …) | Per-VM disk filenames, CLI selection, UUID derivation |
| Guest hostname | `hostname` | In-guest `hostName` / `ComputerName` via env/token plumbing; must equal `name` | Artifact paths or hypervisor names |

Provisioning host (`hosts[]`, `NUCLEUS_HOST`: `MacBook`, `NixOS`, `Windows`) is the physical machine running nucleus — not guest `type`.

### Template tokens

| Token | Manifest field | Substituted into |
| ----- | -------------- | ---------------- |
| `__VM_ID__` | `id` | Hypervisor domain name, `.utm` bundle, `start-<id>.sh` paths, libvirt `<name>` |
| `__VM_DISPLAY__` | `name` | UTM `utmctl start` label, libvirt `<title>` |
| `__GUEST_HOSTNAME__` | `hostname` | Autounattend, Packer guest install |

### Path layout

| Tree | Pattern | Driven by |
| ---- | ------- | --------- |
| Runtime VM dir | `~/virtual machines/src/<type>/` | manifest `type` |
| Repo build templates | `src/vms/<type>/` | manifest `type` (`NixOS`, `Windows`, `macOS`, …) |
| Per-guest disks | `~/virtual machines/data/<id>.qcow2` | manifest `id` |

`src/vms/templates/` is shared scaffolding — not a guest `type` directory.

## VM manifest — required fields

| Field | Type | Description |
| ------------------ | ------- | ----------------------------------------------------------------- |
| `id` | string | Machine-readable key used for files, domains, UUID/MAC derivation, and CLI selection |
| `name` | string | Human-readable label shown in UTM/virt-manager and CLI tables |
| `type` | string | Guest OS family: `"Android"`, `"NixOS"`, `"Windows"`, `"macOS"` |
| `enabled` | bool | Whether the VM is provisioned |
| `hosts` | array | Hosts that provision this VM (`"MacBook"`, `"NixOS"`, `"Windows"`); non-empty |
| `cpus` | int | Number of virtual CPUs |
| `ram` | string | RAM as a suffixed size string per the size grammar (e.g. `"8GB"`) |
| `diskSize` | string | Boot disk size as a suffixed size string per the size grammar (e.g. `"128GB"`) |
| `shareDevDir` | bool | Mount `~/dev` inside the guest via VirtioFS |
| `sound` | string | Audio device: `"intel-hda"` or `"none"` |
| `portForwards` | array | Non-empty `{guestPort, hostPort}` port-forward pairs (see Port forwarding) |
| `hostname` | string | Guest OS hostname; must equal the `name` value (see Hostname convention) |
| `minImageSize` | string | Minimum prebuilt image size floor per the size grammar (e.g. `"4GB"`) |
| `macAddressPrefix` | string | MAC address prefix used for the guest NIC |

Type-specific fields (nested objects keyed by `type`; all fields required when `type` matches, forbidden otherwise):

| `type` | Group | Fields |
| ----------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"Android"` | `Android` | `systemImage`, `userdataImage`, `gsiImage`, `gsiUrl`, `gappsUrl` (all required; `gsiUrl` may be `null` for Lineage-only — no GSI disk; `gappsUrl` is the MindTheGapps zip URL for recovery sideload) |
| `"macOS"` | `macOS` | `version` (release name, e.g. `"tahoe"`) |
| `"Windows"` | `Windows` | `edition` (e.g. `"pro"`), `isoUrl` (`null` = Mido/Fido auto-resolve; a URL auto-downloads the installer ISO when `--windows-iso` is omitted, cached at `~/virtual machines/src/Windows/installer.iso`) |

All common fields and every field in the matching type group are **required** — no optional manifest properties. Deliberate nullable values: `Windows.isoUrl` and `Android.gsiUrl` (`null` is valid; a URL is valid for both).

## Size suffix grammar

All size fields (`ram`, `diskSize`, `minImageSize`) are suffixed size strings matching the grammar below. The grammar is case-sensitive and identical across all three platform parsers (`src/modules/lib/size.nix`, `src/scripts/lib/size.sh`, `src/platforms/Windows/modules/SizeStrings.ps1`); a malformed string aborts provisioning with an error rather than coercing.

```text
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

Guest port forwards are declared in the `portForwards` array of each VM entry: non-empty `{guestPort, hostPort}` pairs mapping a guest port to a host port. All host-side forwards (UTM, QEMU `hostfwd`, Packer, Tart softnet-expose, libvirt passt) and guest-readiness probes derive from this array — never hard-code host ports in production code.

**Reserved host port block:** `22000–22099` (nucleus VM forward range). Every `hostPort` must be unique across all VMs so concurrent guests do not collide.

| VM | Host port(s) | Guest port | Service |
| ---- | ------------- | ------------ | --------- |
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
| --------- | ------------------- | ------------------- |
| UTM (Emulated) | `PortForward` plist dicts from manifest | `localhost:<hostPort>` |
| Windows QEMU | `hostfwd` in start scripts | `localhost:<hostPort>` |
| libvirt/KVM | passt `<portForward><range start='hostPort' to='guestPort'/></portForward>` | `localhost:<hostPort>` |
| Tart (macOS) | `--net-softnet-expose hostPort:guestPort` | Use `tart ip <name>` + SSH guest port `22` (softnet-expose does not bind loopback) |
| Android | Same as QEMU host backend | `adb connect localhost:<hostPort for guest 5555>` |

**Host tooling:** `adb` and `fastboot` are required for `nucleus-vm android-config`. POSIX hosts install them via `pkgs.android-tools` in `src/modules/core.nix` (`nucleus-apply`); the `nucleus-vm` flake app also bundles `android-tools` in its runtime inputs. Windows installs `Google.PlatformTools` via WinGet DSC (`src/hosts/Windows/system/packages.dsc.yml`).

## Disk format

QCOW2 throughout all three platforms. Runtime disks live under `data/`; per-type source payloads and type system images live under `src/<type>/`:

- macOS runtime: `~/virtual machines/data/<id>.qcow2` (UTM bundle exposes `~/virtual machines/<id>.utm/Data/system disk.qcow2` as a hard link)
- NixOS runtime: `~/virtual machines/data/<id>.qcow2`
- Windows runtime: `%USERPROFILE%\virtual machines\data\<id>.qcow2`

UEFI variables are per-VM writable state: macOS stores them at `data/<id> (nvram).fd` (adopted from the UTM-generated `Data/efi_vars.fd` and hard-linked back), Windows at `data/<id> (nvram).fd` (seeded once from the QEMU `edk2-arm-vars.fd` template), and NixOS leaves them to libvirt's per-domain NVRAM copy (no `data/` file).

Type system images land in `~/virtual machines/src/<type>/system image.qcow2` (Windows: `%USERPROFILE%\virtual machines\src\<type>\system image.qcow2`). `nucleus-vm setup` builds each once per type in phase 1 (if absent or drifted); phase 2 creates `data/<id>.qcow2` as a QCOW2 overlay backing directly to the system image.

QCOW2 enables copy-based migration between hosts without conversion.

`src/vms/templates/README.md` is token-replaced at render time; preserve its `__VM_DIR_DISPLAY__` token (and any other `__TOKEN__` placeholders) when editing. README text changes require reconciling `test_vm_readme_template_content` in `tests/modules/vm-setup-tests.nix`.

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
- Bundle disks are hard links only, never copies: `Data/system disk.qcow2` links `data/<id>.qcow2` (non-Android overlay) or `data/<id> (system).qcow2` (Android system overlay); Android additionally links `Data/user data.qcow2` → `data/<id>.qcow2` and `Data/GSI disk.qcow2` → `src/Android/GSI.img` (read-only). Because UTM is sandboxed (QEMUHelper may only open files inside the bundle), every writable overlay also backs onto `Data/system base.qcow2` — a hard link to `src/<type>/system image.qcow2` — so the backing chain stays inside the bundle; non-macOS runtimes back directly onto `src/`. UTM-generated `Data/efi_vars.fd` (UEFI vars) is adopted into `data/<id> (nvram).fd` and hard-linked back by `vm_link_nvram_to_utm_bundle` on sync/setup/unpack.
- After provisioning, UTM opens each bundle automatically.
- VirtioFS shared directory: configured via `Sharing.DirectoryShare` in the Nix-generated config.plist.
- Network: **Emulated** (QEMU user/slirp) — required for `PortForward` to work; vmnet-shared silently drops forwards.
- Template drift: `vm.sh setup` copies the activation-generated `config.plist` template into the bundle only when they differ (`cmp -s`). The check compares template vs bundle — NOT template vs Nix source — so a stale template (activation predating a `src/hosts/MacBook/vms.nix` / `VMs.json` change) propagates silently. Run `nucleus-apply` to regenerate the template before `nucleus-vm setup` after manifest changes.

- `utmctl` CLI path: `/Applications/UTM.app/Contents/MacOS/utmctl`.
- **Running vs registered:** `utmctl list` (via `vm_get_utm_registered_names`) returns every registered VM regardless of `Status`. Running state filters `Status != stopped` (`starting`, `started`, `pausing`, `paused`, `resuming`, `stopping`) via `vm_get_running_ids`.

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

## VM image building — files

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

## VM image building — build strategies

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
