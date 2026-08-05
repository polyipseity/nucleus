# virtual machines

This directory stores VM artifacts managed by `nucleus-vm setup`.

## Layout

```
__VM_DIR_DISPLAY__/
├── tart/                               — Tart VM store (macOS only; symlinked from ~/.tart)
├── images/                             — read-only per-type base images, prebuilt goldens, and build outputs
│   ├── <type>.base.qcow2               — pristine base image (copied from the prebuilt golden at setup)
│   ├── <name>.qcow2                    — pre-built guest image (source for <type>.base.qcow2)
│   ├── <name>.vm-guest-credentials-sha256 — guest credential fingerprint for build image
│   ├── <name>-build/                   — temporary Packer build output (safe to delete)
│   ├── <name>-installer.iso            — cached Windows installer ISO
│   ├── Android-system.qcow2            — Android system image (large download)
│   ├── Android-gsi.img                 — Android GSI image (large download)
│   └── virtio-win.iso                  — shared Windows guest tools ISO (large download)
├── data/                               — writable per-guest runtime disks (one per guest)
│   ├── <id>.qcow2                      — runtime disk (non-Android: overlay backing ../images/<type>.base.qcow2; Android: userdata)
│   └── <id>.qcow2.vm-guest-credentials-sha256 — guest credential fingerprint for runtime disk
├── <id>.vm.json                        — self-describing VM descriptor (all manifest guests)
├── scripts/                            — generated helper scripts
│   ├── start-<id>.sh / .ps1            — start helper variants (all manifest guests, enabled or not)
│   ├── stop-<id>.sh / .ps1             — stop helper variants
│   └── pack.sh / unpack.sh (+ .ps1)    — pack/unpack delegation wrappers
├── <name>.utm/                         — UTM bundle directory (macOS only)
│   ├── config.plist                    — UTM VM configuration
│   └── Data/                           — bundle-local disk files exposed to UTM
│       ├── disk-main.qcow2             — non-Android: hard link to data/<id>.qcow2; Android: copy of Android-system.qcow2
│       ├── <type>.base.qcow2           — hard link to images/<type>.base.qcow2 (non-Android)
│       ├── <userdataImage>             — Android only: hard link to data/<id>.qcow2 (userdata, G1a write-through)
│       └── <gsiImage>                  — Android only: copy of Android-gsi.img (when GSI present)
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
2. SSH port forwarding (host/guest ports from `VMs.json` `portForwards`, per VM)
3. Tart guest agent (macOS guests only)

## Moving VMs between hosts

VM artifacts split into two classes:

- **Regenerable** — trivially regenerable: a pure function of kept inputs plus a trivial command (no downloads, no build time). Rebuilt by `nucleus-vm setup`: `.utm` bundles, `images/<type>.base.qcow2` copies, start/stop scripts.
- **Payload** — copied as-is: `data/<id>.qcow2` runtime disks (including Android userdata, canonical at `data/Android.qcow2`), `images/` prebuilt goldens, Android system/GSI images, installer ISOs, and `<id>.vm.json` descriptors.

To move VMs to another host:

1. Run `nucleus-vm pack` on the source host to strip regenerable artifacts into a compact payload.
2. Copy the packed tree (or the payload files above) to `__VM_DIR_DISPLAY__` on the target host.
3. Run `nucleus-vm unpack` on the target to regenerate platform artifacts (`.utm` bundles, base copies, start/stop scripts) from the descriptors.

Do not copy `.utm` bundles directly — they are regenerable and their bundle-local links would go stale.

### What `nucleus-vm pack` removes

`nucleus-vm pack` refuses while any VM is running. It is dry-run by default: it prints what it would remove; pass `--force` to perform. Only trivially regenerable artifacts (pure function of kept inputs plus a trivial command — no downloads, no build time) plus transient junk are removed:

- `<name>.utm/` bundles (rebuilt by `nucleus-vm unpack` from the descriptor)
- `scripts/start-*.sh` / `stop-*.sh` / `start-*.ps1` / `stop-*.ps1` (sed-rendered from templates)
- `images/<type>.base.qcow2` (copied from the kept prebuilt at setup)
- `images/<name>-build/` and stale dot-directories (transient Packer junk)

Everything else stays: `images/` prebuilt goldens + markers, Android system/GSI images (`Android-system.qcow2`, `Android-gsi.img`), installer caches (`images/*-installer.iso`, `virtio-win.iso`), `data/<id>.qcow2` runtime disks (including Android userdata), `<id>.vm.json` descriptors, runtime markers, `tart/`, `README.md`, and `scripts/pack.sh` / `pack.ps1` / `unpack.sh` / `unpack.ps1` (payload bootstrap).

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
__IMAGES_DIR_DISPLAY__/
└── <name>-build/           — Packer temp files (~10–30 GB)
```

Persistent VM artifacts (remove only when intentionally deleting a VM):

```
__IMAGES_DIR_DISPLAY__/
├── <name>.qcow2                    — pre-built guest image (~2–20 GB)
└── <name>.vm-guest-credentials-sha256 — credential marker for build image
__VM_DIR_DISPLAY__/
├── tart/                           — Tart VM store
├── <name>.utm/                     — UTM bundle
├── data/<id>.qcow2                 — runtime disk
├── data/<id>.qcow2.vm-guest-credentials-sha256 — credential marker for runtime disk
├── <id>.vm.json                    — VM descriptor
└── scripts/
    ├── start-<id>.sh               — POSIX start helper
    └── start-<id>.ps1              — PowerShell start helper
```

## Manual cleanup

These artifacts are preserved by `nucleus-gc` because they are expensive to reproduce. Delete them manually when you need to reclaim space:

- `__IMAGES_DIR_DISPLAY__/<name>-installer.iso` — cached Windows ISO (~5–6 GB). Remove with `rm "__IMAGES_DIR_DISPLAY__/<name>-installer.iso"` (POSIX) or `Remove-Item "__IMAGES_DIR_DISPLAY__/<name>-installer.iso"` (Windows). `nucleus-vm setup` re-downloads it on the next build.

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
- **Drift semantics** — when a guest's credential/config fingerprint changes, `nucleus-vm setup` replaces the *base* (`images/<type>.base.qcow2`) from the kept prebuilt golden and keeps the *overlay* (`data/<id>.qcow2`), so user data survives rebuilds.
- **Resize semantics** — `data/<id>.qcow2` is grow-only: `nucleus-vm resize <id> <size>` grows it, `nucleus-vm setup` auto-grows to the manifest `diskSize`, and shrinking requires `--allow-shrink`.
- **Generated `.sh` scripts** use `#!/usr/bin/env bash` with `set -euo pipefail` — never `#!/bin/sh`.
- The Tart store directory was renamed from `.tart` to `tart/`; both are symlinked from `~/.tart` on macOS.
- **UTM hard links** — non-Android bundles expose `Data/disk-main.qcow2` → `data/<id>.qcow2` and `Data/<type>.base.qcow2` → `images/<type>.base.qcow2` as hard links; Android bundles expose `Data/<userdataImage>` → `data/Android.qcow2` (G1a, live-verified). Non-Android backing resolution through the bundle link is assumed working only (user-confirmed 2026-08-04; live-verified only for Android userdata, which has no backing chain).
