# virtual machines

This directory stores VM artifacts managed by `nucleus-vm-setup`.

## Layout

```
{{VM_DIR_DISPLAY}}/
├── .tart/                              — Tart VM store (macOS only; symlinked from ~/.tart)
├── images/                             — build outputs, temporary build dirs, installer cache
│   ├── <name>.qcow2                    — pre-built guest image
│   ├── <name>-build/                   — temporary Packer build output (safe to delete)
│   ├── <name>-installer.iso            — cached Windows installer ISO
│   └── <name>.vm-guest-credentials-sha256 — guest credential fingerprint for build image
├── scripts/                            — generated start helper scripts
│   ├── start-<name>.sh                 — POSIX start helper
│   └── start-<name>.ps1                — PowerShell start helper
├── <name>.utm/                         — UTM bundle directory (macOS only)
│   ├── config.plist                    — UTM VM configuration
│   └── Data/disk-main.qcow2            — UTM runtime disk
├── <name>.qcow2                        — libvirt/QEMU runtime disk (Linux/Windows only)
├── <name>.qcow2.vm-guest-credentials-sha256 — guest credential fingerprint for runtime disk
└── README.md                           — this file
```

## Start commands

| Host OS | Guest type | Hypervisor | Command |
|---|---|---|---|
| macOS | macOS | Tart | `scripts/start-<name>.sh` or `scripts/start-<name>.ps1` |
| macOS | NixOS / Windows | UTM | `scripts/start-<name>.sh` or `scripts/start-<name>.ps1` |
| NixOS | NixOS / Windows | libvirt | `scripts/start-<name>.sh` or `scripts/start-<name>.ps1` |
| Windows | NixOS / Windows | QEMU | `scripts/start-<name>.ps1` (`scripts/start-<name>.sh` in Git Bash) |

Run from `{{VM_DIR_DISPLAY}}/scripts/`.

## Guest configuration

Guest OS converge happens automatically after provisioning (Packer, guest.nix,
or Tart bootstrap). If you need to re-configure manually, run inside the guest:

- **NixOS guest**: `sudo nixos-rebuild switch --flake "$HOME/dev/nucleus/src#NixOS"`
- **Windows guest**: `.\src\hosts\Windows\apply.ps1` (from `%USERPROFILE%\dev\nucleus`)
- **macOS guest**: `~/dev/nucleus/scripts/bootstrap.sh apply`

Automation channels used during provisioning:

1. QEMU guest agent (virtio-serial named pipe — all QEMU-based VMs)
2. SSH port forwarding (`localhost:2222` — NixOS guests only)
3. Tart guest agent (macOS guests only)

## UTM bundle portability

`*.utm` is a folder bundle (not a single opaque file). It contains VM metadata
plus disk data (typically `Data/disk-main.qcow2`).

To move a UTM VM to another macOS host:

1. Copy the entire `<name>.utm` directory.
2. Place it under `{{VM_DIR_DISPLAY}}` on the target host.
3. Open it in UTM (or re-run `nucleus-vm-setup` to refresh the managed registration).

Copying only `config.plist` or only `disk-main.qcow2` is not sufficient for a
portable UTM VM transfer.

## Lifecycle

```
build → provision → run → rebuild
```

1. **Build** — `nucleus-vm-setup` builds guest images (nixos-generators, Packer).
2. **Provision** — Guest boots, automation channels converge guest state.
3. **Run** — Generated start scripts launch the VM for daily use.
4. **Rebuild** — Re-run `nucleus-vm-setup` to rebuild images after config changes.

## Safe cleanup

Temporary files/directories that are safe to remove when builds fail, are
interrupted, or when reclaiming space:

```
{{IMAGES_DIR_DISPLAY}}/
└── <name>-build/           — Packer temp files (~10–30 GB)
```

Persistent VM artifacts (remove only when intentionally deleting a VM):

```
{{IMAGES_DIR_DISPLAY}}/
├── <name>.qcow2                    — pre-built guest image (~2–20 GB)
└── <name>.vm-guest-credentials-sha256 — credential marker for build image
{{VM_DIR_DISPLAY}}/
├── .tart/                          — Tart VM store
├── <name>.utm/                     — UTM bundle
├── <name>.qcow2                    — runtime disk
├── <name>.qcow2.vm-guest-credentials-sha256 — credential marker for runtime disk
└── scripts/
    ├── start-<name>.sh             — POSIX start helper
    └── start-<name>.ps1            — PowerShell start helper
```

## Manual cleanup

These artifacts are preserved by `nucleus-gc` because they are expensive to
reproduce. Delete them manually when you need to reclaim space:

- `{{IMAGES_DIR_DISPLAY}}/<name>-installer.iso` — cached Windows ISO (~5–6 GB).
  Remove with `rm "{{IMAGES_DIR_DISPLAY}}/<name>-installer.iso"` (POSIX) or
  `Remove-Item "{{IMAGES_DIR_DISPLAY}}/<name>-installer.iso"` (Windows).
  `nucleus-vm-setup` re-downloads it on the next build.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Build slow on Windows | WHPX not enabled | `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart` |
| Packer fails / timeout | Missing SSH key or incorrect credentials | Verify `src/secrets/users-*.yml` and re-run `nucleus-vm-setup` |
| SSH connection refused | Guest not booted or SSH not started | Check guest status; start VM and wait 60s before retry |
| QEMU GA not responding | Guest agent not running inside guest | Verify `qemu-guest-agent` service is enabled in guest config |
| `virsh start` fails on NixOS | libvirt pool not defined | Run `virsh pool-define-as nucleus dir --target /var/lib/libvirt/images` |

## Notes

- Keep this directory managed by `nucleus-vm-setup`; avoid hand-editing generated artifacts.
- Re-run `nucleus-vm-setup` after changing `src/modules/VMs.json`.
- macOS guest images are built and run with Tart today; automated Tart→UTM runtime handoff is not yet supported.
