# virtual machines

This directory stores VM artifacts managed by `nucleus-vm setup`. Lifecycle, pack/unpack, GC, guest configuration, and migration policy: `.agents/instructions/vm-management.instructions.md`.

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
│   │   ├── system image.qcow2          — type system image (built once per type)
│   │   ├── system image.vm-type-config-sha256 — type-config fingerprint
│   │   └── Packer/                     — temporary Packer build output (safe to delete)
│   ├── Windows/
│   │   ├── system image.qcow2          — type system image (built once per type)
│   │   ├── system image.vm-type-config-sha256 — type-config fingerprint
│   │   ├── installer.iso               — cached Windows installer ISO
│   │   ├── virtio guest tools.iso      — shared Windows guest tools ISO (large download)
│   │   └── Packer/                     — temporary Packer build output (safe to delete)
│   └── macOS/                          — macOS guest payloads (Tart-managed)
├── data/                               — writable per-guest runtime disks
│   ├── <id>.qcow2                      — writable overlay (non-Android: backs __VM_DIR_DISPLAY__/src/<type>/system image.qcow2 — or the bundle-local system base on macOS; Android: userdata)
│   ├── <id> (system).qcow2             — Android: writable overlay backing __VM_DIR_DISPLAY__/src/Android/system image.qcow2 (guest /system; on macOS backs __VM_DIR_DISPLAY__/<id>.utm/Data/system base.qcow2)
│   └── <id>.qcow2.vm-provision-sha256  — provision fingerprint for runtime disk
├── <id>.vm.json                        — self-describing VM descriptor (all manifest guests)
├── scripts/                            — generated helper scripts
│   ├── start-<id>.sh / .ps1            — start helper variants (all manifest guests, enabled or not)
│   ├── stop-<id>.sh / .ps1             — stop helper variants
│   └── pack.sh / unpack.sh (+ .ps1)    — pack/unpack delegation wrappers
├── <name>.utm/                         — UTM bundle directory (macOS only)
│   ├── config.plist                    — UTM VM configuration
│   └── Data/                           — bundle-local disk files exposed to UTM (hard links only, never copies)
│       ├── system base.qcow2           — hard link: src/<type>/system image.qcow2 (read-only base; the writable overlay backs onto this bundle-local link because UTM's sandbox only exposes the bundle to QEMUHelper)
│       ├── system disk.qcow2           — hard link: non-Android → data/<id>.qcow2 overlay; Android → data/<id> (system).qcow2 overlay
│       ├── user data.qcow2             — Android only: hard link to data/<id>.qcow2 (G1a write-through)
│       └── GSI disk.qcow2              — Android only: hard link to src/Android/GSI.img (read-only, when GSI present)
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

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Build slow on Windows | WHPX not enabled | `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart` |
| Packer fails / timeout | Missing SSH key or incorrect credentials | Verify `src/secrets/users-*.yml` and re-run `nucleus-vm setup` |
| SSH connection refused | Guest not booted or SSH not started | Check guest status; start VM and wait 60s before retry |
| QEMU GA not responding | Guest agent not running inside guest | Verify `qemu-guest-agent` service is enabled in guest config |
| `virsh start` fails on NixOS | libvirt pool not defined | Run `virsh pool-define-as nucleus dir --target /var/lib/libvirt/images` |
