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

macOS guest: Tart only (Apple Virtualization.framework). No automated Tart→UTM handoff.

## Guest identity — field contract

| Field | Manifest key | Use for | Never use for |
| ----- | ------------ | ------- | ------------- |
| Guest ID | `id` | CLI args (`nucleus-vm start NixOS`), `data/<id>.qcow2`, `<id>.vm.json`, `start-<id>.sh`, virsh/utm/tart domain name, UUID/MAC derivation, running-VM probes, GC keep sets | OS-family paths, build branching, display labels |
| Display name | `name` | UTM window title, libvirt `<title>`, CLI table human column, log labels (`-VmDisplay`) | File paths, CLI args, hypervisor domain name |
| OS type | `type` | `~/virtual machines/src/<type>/` runtime artifacts, `src/vms/<type>/` build templates, per-type GC, build branching, type-specific nested groups (`Android`, `Windows`, …) | Per-VM disk filenames, CLI selection, UUID derivation |
| Guest hostname | `hostname` | In-guest `hostName` / `ComputerName` via env/token plumbing; must equal `name` | Artifact paths or hypervisor names |

Provisioning host (`hosts[]`, `NUCLEUS_HOST`: `MacBook`, `NixOS`, `Windows`) is the physical machine, not guest `type`.

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
| --- | --- | --- |
| `id` | string | File paths, domains, UUID/MAC, CLI |
| `name` | string | Display label (UTM/virt-manager, CLI tables) |
| `type` | string | `"Android"`, `"NixOS"`, `"Windows"`, `"macOS"` |
| `enabled` | bool | Provisioned |
| `hosts` | array | `"MacBook"`, `"NixOS"`, `"Windows"`; non-empty |
| `cpus` | int | Virtual CPUs |
| `ram` | string | Size string (e.g. `"8GB"`) |
| `diskSize` | string | Boot disk size |
| `shareDevDir` | bool | Mount `~/dev` via VirtioFS |
| `sound` | string | `"intel-hda"` or `"none"` |
| `portForwards` | array | `{guestPort, hostPort}` pairs |
| `hostname` | string | Must equal `name` |
| `minImageSize` | string | Minimum image size floor |
| `macAddressPrefix` | string | Guest NIC MAC prefix |

Type-specific fields (all required when `type` matches, forbidden otherwise):

| `type` | Group | Fields |
| ----------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"Android"` | `Android` | `systemImage`, `userdataImage`, `gsiImage`, `gsiUrl`, `gappsUrl` (all required; `gsiUrl` may be `null` for Lineage-only — no GSI disk; `gappsUrl` is the MindTheGapps zip URL for recovery sideload) |
| `"macOS"` | `macOS` | `version` (release name, e.g. `"tahoe"`) |
| `"Windows"` | `Windows` | `edition` (e.g. `"pro"`), `isoUrl` (`null` = Mido/Fido auto-resolve; a URL auto-downloads the installer ISO when `--windows-iso` is omitted, cached at `~/virtual machines/src/Windows/installer.iso`) |

All fields required — no optional properties. Deliberate nullable: `Windows.isoUrl`, `Android.gsiUrl`.

## Size suffix grammar

All size fields (`ram`, `diskSize`, `minImageSize`) use suffixed strings. Grammar identical across parsers (`src/modules/lib/size.nix`, `src/scripts/lib/size.sh`, `src/platforms/Windows/modules/SizeStrings.ps1`); malformed strings abort.

```text
^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$
```

- **Decimal prefixes** `kB`, `MB`, `GB`, `TB` multiply by powers of 10 (×10³, ×10⁶, ×10⁹, ×10¹²).
- **Binary prefixes** `kiB`, `MiB`, `GiB`, `TiB` multiply by powers of 2 (×2¹⁰, ×2²⁰, ×2³⁰, ×2⁴⁰).
- A single optional space between number and prefix: `"8GB"`, `"8 GB"`, `"8192MiB"`.
- `KB`/`KiB` (capital K) invalid. IEC binary prefix is `Ki`; `k` always lowercase.
- Canonical values use decimal prefixes (`"8GB"`, `"128GB"`). Binary accepted but not convention.
- Property names carry no unit — the suffix carries it (`ram`, `diskSize`, `minImageSize`; never `ramBytes`).
- Canonical internal unit: integer bytes. 1024-based math confined to parsers and documented adapters.

## Port forwarding

Port forwards declared in `portForwards` array: `{guestPort, hostPort}` pairs. All host-side forwards and probes derive from this — never hard-code ports.

**Reserved block:** `22000–22099`. Every `hostPort` unique across VMs.

| VM | Host port(s) | Guest port | Service |
| ---- | ------------- | ------------ | --------- |
| MacBook | `22010` | `22` | SSH |
| NixOS | `22020` | `22` | SSH |
| Windows | `22030` | `22` | SSH |
| Android | `22040` | `5555` | ADB |
| Android | `22041` | `5554` | Emulator console |

- Non-Android: one `guestPort: 22` SSH entry. Android: `guestPort: 5555` (ADB) + `guestPort: 5554` (console), no `guestPort: 22`.
- UTM/QEMU/libvirt render every entry generically. QEMU/Packer: `hostfwd=tcp::<hostPort>-:<guestPort>`.
- Probes resolve host port by `guestPort` (`22` SSH, `5555` ADB) — never by literal host port.

| Backend | Forward mechanism | Host-local access |
| --------- | ------------------- | ------------------- |
| UTM (Emulated) | `PortForward` plist dicts from manifest | `localhost:<hostPort>` |
| Windows QEMU | `hostfwd` in start scripts | `localhost:<hostPort>` |
| libvirt/KVM | passt `<portForward><range start='hostPort' to='guestPort'/></portForward>` | `localhost:<hostPort>` |
| Tart (macOS) | `--net-softnet-expose hostPort:guestPort` | Use `tart ip <name>` + SSH guest port `22` (softnet-expose does not bind loopback) |
| Android | Same as QEMU host backend | `adb connect localhost:<hostPort for guest 5555>` |

Host tooling: `adb`/`fastboot` for `android-config`. POSIX: `pkgs.android-tools` in `core.nix`. Windows: `Google.PlatformTools` via WinGet.

## Disk format

QCOW2 throughout. Runtime disks in `data/`; system images in `src/<type>/`. Copy-based migration between hosts.

- macOS runtime: `~/virtual machines/data/<id>.qcow2` (UTM bundle exposes `~/virtual machines/<id>.utm/Data/system disk.qcow2` as a hard link)
- NixOS runtime: `~/virtual machines/data/<id>.qcow2`
- Windows runtime: `%USERPROFILE%\virtual machines\data\<id>.qcow2`

UEFI vars: macOS `data/<id> (nvram).fd` (from UTM `efi_vars.fd`); Windows same (from `edk2-arm-vars.fd`); NixOS uses libvirt NVRAM.

System images: `~/virtual machines/src/<type>/system image.qcow2`. Phase 1 builds once per type; phase 2 creates overlay.

`src/vms/templates/README.md` is token-replaced; preserve `__VM_DIR_DISPLAY__`. Changes require `test_vm_readme_template_content` reconciliation.

## macOS — Tart

- Backend: Tart CLI (Apple Virtualization.framework); macOS host only.
- Store: `~/virtual machines/tart/vms/<id>/` — `~/.tart` symlinked to `~/virtual machines/tart` by `nucleus-vm setup`.
- Build: Packer + `tart-cli` plugin pulling `ghcr.io/cirruslabs/macos-<version>-base:latest`.
- Start: `tart run --net-softnet --net-softnet-expose <hostPort>:<guestPort> <id>`. SSH via `tart ip <id>` + port 22 (not localhost).
- No UTM bundle for macOS guests.
- Running state: `tart list --format json` + `.Running == true` via `vm_get_running_ids`.

## macOS — UTM

- Backend: UTM 4.x QEMU. Bundle: `~/virtual machines/<id>.utm/`.
- Config: `config.plist` pre-generated at `~/.local/share/nucleus/vms/<id>-config.plist` by `src/hosts/MacBook/vms.nix`; `vm.sh setup` copies into bundle.
- Disks: hard links only. `Data/system disk.qcow2` links `data/<id>.qcow2` (or `<id> (system).qcow2` for Android). Android adds `Data/user data.qcow2` + `Data/GSI disk.qcow2`. UTM sandbox requires backing chain inside bundle — writable overlays back onto `Data/system base.qcow2` (hard link to `src/<type>/system image.qcow2`). UTM-generated `Data/efi_vars.fd` adopted into `data/<id> (nvram).fd`.
- Network: **Emulated** (QEMU user/slirp) — vmnet-shared drops forwards.
- Template drift: `vm.sh setup` compares template vs bundle (`cmp -s`), not vs Nix source. Run `nucleus-apply` after manifest changes.
- `utmctl`: `/Applications/UTM.app/Contents/MacOS/utmctl`.
- Running state: `utmctl list` returns all registered VMs; filter `Status != stopped` via `vm_get_running_ids`.

## NixOS — libvirt/KVM

- Infrastructure: `src/hosts/NixOS/vms.nix` (system module).
- Packages: `qemu_kvm`, `virt-manager`, `virt-viewer`, `virtiofsd`, `passt`.
- Groups: `kvm`, `libvirtd` added to managed user.
- Domain XML: pre-generated at `/etc/nucleus/vms/<name>-domain.xml`; `vm.sh setup` calls `virsh define`.
- Networking: passt with `<portForward>` from manifest.
- VirtioFS via `virtiofsd`. SPICE display + clipboard. OVMF (UEFI) + swtpm (TPM) for Windows 11.
- Start with `start-<name>.sh`/`.ps1` or `virt-manager`.

## Windows — QEMU via Scoop

- QEMU via Scoop extras bucket (`Invoke-ScoopSetup.ps1`).
- Disks and start scripts in `%USERPROFILE%\virtual machines\`.
- Start script: `start-<name>.ps1` (self-contained).
- VirtioFS requires `virtiofsd` as separate process. See `~/virtual machines/README.md`.
