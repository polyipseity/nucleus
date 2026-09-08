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

| Field | Use for | Never use for |
| --- | --- | --- |
| `id` | CLI, files, domain name, UUID/MAC, GC probes | Paths, build branching, display |
| `name` | UTM title, libvirt title, CLI table, logs | Paths, CLI args, domain name |
| `type` | `~/…/src/<type>/`, build templates, per-type GC | Disk filenames, CLI selection, UUID |
| `hostname` | In-guest `hostName`/`ComputerName`; must equal `name` | Artifact paths, domain names |

Provisioning host (`hosts[]`, `NUCLEUS_HOST`) is the physical machine, not guest `type`.

### Template tokens

`__VM_ID__` → domain/bundle/paths. `__VM_DISPLAY__` → UTM label/libvirt title. `__GUEST_HOSTNAME__` → Autounattend/Packer install.

### Path layout

Runtime: `~/virtual machines/src/<type>/`. Build templates: `src/vms/<type>/`. Disks: `~/virtual machines/data/<id>.qcow2`. `src/vms/templates/` is shared scaffolding, not a type directory.

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

| `type` | Fields |
| --- | --- |
| `"Android"` | `systemImage`, `userdataImage`, `gsiImage`, `gsiUrl` (nullable), `gappsUrl` (MindTheGapps zip) |
| `"macOS"` | `version` (e.g. `"tahoe"`) |
| `"Windows"` | `edition` (e.g. `"pro"`), `isoUrl` (nullable: `null` = auto-resolve) |

All fields required. Nullable: `Windows.isoUrl`, `Android.gsiUrl`.

## Size suffix grammar

All size fields use suffixed strings. Identical grammar across parsers (`size.nix`, `size.sh`, `SizeStrings.ps1`); malformed strings abort.

```text
^[0-9]+ ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$
```

- Decimal: `kB`, `MB`, `GB`, `TB` (powers of 10). Binary: `kiB`, `MiB`, `GiB`, `TiB` (powers of 2).
- Optional space allowed: `"8GB"`, `"8 GB"`. `KB`/`KiB` invalid; `k` always lowercase.
- Canonical: decimal (`"8GB"`, `"128GB"`). Binary accepted but not convention.
- Suffix carries unit; property names carry none. Internal unit: integer bytes.

## Port forwarding

`portForwards`: `{guestPort, hostPort}` pairs. All forwards and probes derive from this — never hard-code. **Reserved:** `22000–22099`.

| VM | Host port(s) | Guest port | Service |
| ---- | ------------- | ------------ | --------- |
| MacBook | `22010` | `22` | SSH |
| NixOS | `22020` | `22` | SSH |
| Windows | `22030` | `22` | SSH |
| Android | `22040` | `5555` | ADB |
| Android | `22041` | `5554` | Emulator console |

- Non-Android: one `guestPort: 22`. Android: `5555` (ADB) + `5554` (console), no `22`.
- UTM/QEMU/libvirt render generically. QEMU/Packer: `hostfwd=tcp::<hostPort>-:<guestPort>`.
- Probes resolve by `guestPort` (`22` SSH, `5555` ADB), never literal host port.

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

- Backend: Tart CLI (Apple Virtualization.framework); macOS only. Store: `~/virtual machines/tart/vms/<id>/`.
- Build: Packer + `tart-cli` plugin from GHCR. Start: `tart run --net-softnet --net-softnet-expose <hostPort>:<guestPort> <id>`. SSH: `tart ip <id>` + port 22.
- Running: `tart list --format json` + `.Running == true` via `vm_get_running_ids`.

## macOS — UTM

- Backend: UTM 4.x QEMU. Bundle: `~/virtual machines/<id>.utm/`.
- Config: `config.plist` pre-generated by `src/hosts/MacBook/vms.nix`; `vm.sh setup` copies into bundle.
- Disks: hard links only. Writable overlays back onto `Data/system base.qcow2` (hard link to `src/<type>/system image.qcow2`) for UTM sandbox. Android adds extra disk links. `efi_vars.fd` adopted into `data/<id> (nvram).fd`.
- Network: emulated (QEMU user/slirp) — vmnet-shared drops forwards.
- Template drift: `vm.sh setup` compares template vs bundle (`cmp -s`), not vs Nix source. Run `nucleus-apply` after manifest changes.
- `utmctl`: `/Applications/UTM.app/Contents/MacOS/utmctl`. Running: filter `Status != stopped` via `vm_get_running_ids`.

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
