# virtual machines

This directory stores VM artifacts managed by `nucleus-vm setup`.

## Layout

```
__VM_DIR_DISPLAY__/
├── tart/                               — Tart VM store (macOS only; symlinked from ~/.tart)
├── src/                                — per-guest-type source payloads and build outputs
│   ├── Android/
│   │   ├── system image.qcow2          — Android system image (large download)
│   │   ├── GSI.img                     — Android GSI image (when gsiUrl is set)
│   │   ├── recovery userdebug.img      — cached Lineage recovery for android-config
│   │   ├── recovery userdebug.tag.json — recovery cache tag
│   │   ├── boot.img                    — cached boot image for Magisk workflows
│   │   ├── boot.tag.json               — boot image cache tag
│   │   ├── Magisk.apk                  — cached Magisk APK
│   │   ├── boot Magisk patched.img     — Magisk-patched boot image
│   │   ├── GApps.zip                   — cached MindTheGapps zip
│   │   ├── Magisk patch kit/           — Magisk patch working directory
│   │   ├── Lineage download.zip        — cached LineageOS zip
│   │   └── Lineage extract/            — extracted Lineage artifacts
│   ├── NixOS/
│   │   ├── prebuilt image.qcow2        — golden pre-built guest image
│   │   ├── overlay backing.qcow2       — pristine base (copied from prebuilt at setup)
│   │   ├── prebuilt image.vm-guest-credentials-sha256 — credential fingerprint for prebuilt
│   │   ├── prebuilt image.vm-guest-config-sha256      — guest-config fingerprint for prebuilt
│   │   └── Packer/                     — temporary Packer build output (safe to delete)
│   ├── Windows/
│   │   ├── prebuilt image.qcow2        — golden pre-built guest image
│   │   ├── overlay backing.qcow2       — pristine base (copied from prebuilt at setup)
│   │   ├── installer.iso               — cached Windows installer ISO
│   │   ├── virtio guest tools.iso      — shared Windows guest tools ISO (large download)
│   │   ├── prebuilt image.vm-guest-credentials-sha256 — credential fingerprint for prebuilt
│   │   └── Packer/                     — temporary Packer build output (safe to delete)
│   └── macOS/                          — macOS guest payloads (Tart-managed)
├── data/                               — writable per-guest runtime disks
│   ├── <id>.qcow2                      — runtime overlay (non-Android: backs ../src/<type>/overlay backing.qcow2; Android: userdata)
│   └── <id>.qcow2.vm-guest-credentials-sha256 — credential fingerprint for runtime disk
├── <id>.vm.json                        — self-describing VM descriptor (all manifest guests)
├── scripts/                            — generated helper scripts
│   ├── start-<id>.sh / .ps1            — start helper variants (all manifest guests, enabled or not)
│   ├── stop-<id>.sh / .ps1             — stop helper variants
│   └── pack.sh / unpack.sh (+ .ps1)    — pack/unpack delegation wrappers
├── <name>.utm/                         — UTM bundle directory (macOS only)
│   ├── config.plist                    — UTM VM configuration
│   └── Data/                           — bundle-local disk files exposed to UTM
│       ├── disk-main.qcow2             — non-Android: hard link to data/<id>.qcow2; Android: copy of src/Android/system image.qcow2
│       ├── overlay backing.qcow2       — non-Android only: hard link to src/<type>/overlay backing.qcow2
│       ├── <userdataImage>             — Android only: hard link to data/<id>.qcow2 (userdata, G1a write-through)
│       └── <gsiImage>                  — Android only: copy of src/Android/GSI.img (when GSI present)
└── README.md                           — this file
```

## Start commands

| Host OS | Guest type | Hypervisor | Command |
|---|---|---|---|
| macOS | macOS | Tart | `scripts/start-<id>.sh` or `scripts/start-<id>.ps1` |
| macOS | NixOS / Windows | UTM | `scripts/start-<id>.sh` or `scripts/start-<id>.ps1` |
| NixOS | NixOS / Windows | libvirt | `scripts/start-<id>.sh` or `scripts/start-<id>.ps1` |
| Windows | NixOS / Windows | QEMU | `scripts/start-<id>.ps1` (`scripts/start-<id>.sh` in Git Bash) |

Run from `__VM_DIR_DISPLAY__/scripts/`.

## Guest configuration

Guest OS converge happens automatically after provisioning (Packer, guest.nix, or Tart bootstrap). If you need to re-configure manually, run inside the guest:

- **NixOS guest**: `sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"`
- **Windows guest**: `.\src\hosts\Windows\apply.ps1` (from `%USERPROFILE%\dev\nucleus`)
- **macOS guest**: `~/dev/nucleus/scripts/bootstrap.sh apply`

Automation channels used during provisioning:

1. QEMU guest agent (virtio-serial named pipe — all QEMU-based VMs)
2. Port forwarding tokens from `VMs.json` `portForwards`: `__HOSTFWDS__` (QEMU), `__VM_PORT_FORWARDS__` (UTM plist), `__TART_SOFTNET_EXPOSE__` (Tart), libvirt passt ranges (NixOS domain XML)
3. Tart guest agent (macOS guests only)

## Moving VMs between hosts

VM artifacts split into two classes:

- **Regenerable** — trivially regenerable: a pure function of kept inputs plus a trivial command (no downloads, no build time). Rebuilt by `nucleus-vm setup`: `.utm` bundles, `src/<type>/overlay backing.qcow2` copies, start/stop scripts.
- **Payload** — copied as-is: `data/<id>.qcow2` runtime disks (including Android userdata, canonical at `data/Android.qcow2`), `src/` prebuilt goldens and Android system/GSI images, installer ISOs, virtio guest tools ISO, and `<id>.vm.json` descriptors.

To move VMs to another host:

1. Run `nucleus-vm pack` on the source host to strip regenerable artifacts into a compact payload.
2. Copy the packed tree (or the payload files above) to `__VM_DIR_DISPLAY__` on the target host.
3. Run `nucleus-vm unpack` on the target to regenerate platform artifacts (`.utm` bundles, base copies, start/stop scripts) from the descriptors.

Do not copy `.utm` bundles directly — they are regenerable and their bundle-local links would go stale.

### What `nucleus-vm pack` removes

`nucleus-vm pack` refuses while any VM is running. It is dry-run by default: it prints what it would remove; pass `--force` to perform. Only trivially regenerable artifacts (pure function of kept inputs plus a trivial command — no downloads, no build time) plus transient junk are removed:

- `<name>.utm/` bundles (rebuilt by `nucleus-vm unpack` from the descriptor)
- `scripts/start-*.sh` / `stop-*.sh` / `start-*.ps1` / `stop-*.ps1` (sed-rendered from templates)
- `src/<type>/overlay backing.qcow2` (copied from the kept prebuilt at setup)
- `src/<type>/Packer/` and stale dot-directories under `src/<type>/` (transient Packer junk)

Everything else stays: `src/` prebuilt goldens + markers, Android system/GSI images (`system image.qcow2`, `GSI.img`), installer caches (`installer.iso`, `virtio guest tools.iso`), `data/<id>.qcow2` runtime disks (including Android userdata), `<id>.vm.json` descriptors, runtime markers, `tart/`, `README.md`, and `scripts/pack.sh` / `pack.ps1` / `unpack.sh` / `unpack.ps1` (payload bootstrap).

> **Android userdata:** canonical at `data/Android.qcow2`; the bundle copy is a hard link (G1a), so guest writes go straight through and `nucleus-vm pack` preserves userdata automatically. No manual sync-out is needed.

## Lifecycle

```
build → provision → run → rebuild
```

1. **Build** — `nucleus-vm setup` builds guest images (nixos-generators, Packer).
2. **Provision** — Guest boots, automation channels converge guest state.
3. **Run** — Generated start scripts launch the VM for daily use.
4. **Rebuild** — Re-run `nucleus-vm setup` to rebuild images after config changes.

## Safe cleanup

Temporary files/directories that are safe to remove when builds fail, are interrupted, or when reclaiming space:

```
__SRC_DIR_DISPLAY__/
├── <type>/Packer/                      — Packer temp files (~10–30 GB)
└── <type>/.<id>.<firmware>.<boot>.*/  — transient Packer attempt directories
```

Persistent VM artifacts (remove only when intentionally deleting a VM):

```
__SRC_DIR_DISPLAY__/
├── <type>/prebuilt image.qcow2         — pre-built guest image (~2–20 GB)
└── <type>/prebuilt image.vm-guest-credentials-sha256 — credential marker for prebuilt
__VM_DIR_DISPLAY__/
├── tart/                               — Tart VM store
├── <name>.utm/                         — UTM bundle
├── data/<id>.qcow2                     — runtime disk
├── data/<id>.qcow2.vm-guest-credentials-sha256 — credential marker for runtime disk
├── <id>.vm.json                        — VM descriptor
└── scripts/
    ├── start-<id>.sh                   — POSIX start helper
    └── start-<id>.ps1                  — PowerShell start helper
```

## Manual cleanup

### GC guarantees

Weekly `nucleus-gc` and explicit `nucleus-vm gc` preserve every guest listed in `src/modules/VMs.json` — enabled or disabled, on any host — plus every manifest-referenced `src/<type>/` image (`prebuilt image.qcow2`, `overlay backing.qcow2`, Android system/GSI). `data/<id>.qcow2` userdata/overlays are preserved by default; pass `--gc-data` to also GC orphaned runtime disks and their markers. Only artifacts with no matching manifest entry are removed. Pass `--gc-disabled` to narrow the keep-set to enabled guests on the current host only. VM GC is opt-in via `nucleus-vm gc` (or the VM step inside `nucleus-gc`); `nucleus-vm pack` is dry-run by default (`--force` performs).

These artifacts are preserved by `nucleus-gc` because they are expensive to reproduce. Delete them manually when you need to reclaim space:

- `__SRC_DIR_DISPLAY__/Windows/installer.iso` — cached Windows ISO (~5–6 GB). Remove with `rm "__SRC_DIR_DISPLAY__/Windows/installer.iso"` (POSIX) or `Remove-Item "__SRC_DIR_DISPLAY__/Windows/installer.iso"` (Windows). `nucleus-vm setup` re-downloads it on the next build.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Build slow on Windows | WHPX not enabled | `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart` |
| Packer fails / timeout | Missing SSH key or incorrect credentials | Verify `src/secrets/users-*.yml` and re-run `nucleus-vm setup` |
| SSH connection refused | Guest not booted or SSH not started | Check guest status; start VM and wait 60s before retry |
| QEMU GA not responding | Guest agent not running inside guest | Verify `qemu-guest-agent` service is enabled in guest config |
| `virsh start` fails on NixOS | libvirt pool not defined | Run `virsh pool-define-as nucleus dir --target /var/lib/libvirt/images` |

## Notes

- Keep this directory managed by `nucleus-vm setup`; avoid hand-editing generated artifacts.
- Re-run `nucleus-vm setup` after changing `src/modules/VMs.json`.
- macOS guest images are built and run with Tart today; automated Tart→UTM runtime handoff is not yet supported.
- **Drift semantics** — when a guest's credential/config fingerprint changes, `nucleus-vm setup` replaces the *base* (`src/<type>/overlay backing.qcow2`) from the kept prebuilt golden and keeps the *overlay* (`data/<id>.qcow2`), so user data survives rebuilds.
- **Resize semantics** — `data/<id>.qcow2` is grow-only: `nucleus-vm resize <id> <size>` grows it, `nucleus-vm setup` auto-grows to the manifest `diskSize`, and shrinking requires `--allow-shrink`.
- **Generated `.sh` scripts** use `#!/usr/bin/env bash` with `set -euo pipefail` — never `#!/bin/sh`.
- The Tart store directory was renamed from `.tart` to `tart/`; both are symlinked from `~/.tart` on macOS.
- **UTM hard links** — non-Android bundles expose `Data/disk-main.qcow2` → `data/<id>.qcow2` and `Data/overlay backing.qcow2` → `src/<type>/overlay backing.qcow2` as hard links; Android bundles expose `Data/<userdataImage>` → `data/Android.qcow2` (G1a, live-verified). Non-Android backing resolution through the bundle link is assumed working only (user-confirmed 2026-08-04; live-verified only for Android userdata, which has no backing chain).
