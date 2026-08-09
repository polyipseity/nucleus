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
│       ├── <userdataImage>             — Android only: hard link to data/<id>.qcow2 (G1a write-through)
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

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Build slow on Windows | WHPX not enabled | `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart` |
| Packer fails / timeout | Missing SSH key or incorrect credentials | Verify `src/secrets/users-*.yml` and re-run `nucleus-vm setup` |
| SSH connection refused | Guest not booted or SSH not started | Check guest status; start VM and wait 60s before retry |
| QEMU GA not responding | Guest agent not running inside guest | Verify `qemu-guest-agent` service is enabled in guest config |
| `virsh start` fails on NixOS | libvirt pool not defined | Run `virsh pool-define-as nucleus dir --target /var/lib/libvirt/images` |
