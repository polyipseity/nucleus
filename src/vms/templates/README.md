# virtual machines

This directory stores VM artifacts managed by `nucleus-vm-setup`.

## Layout

- `.tart/` — Tart VM store on macOS hosts (symlinked from `~/.tart`).
- `images/` — build outputs, temporary build directories, and installer cache.
  Build artifacts are separated from runtime disks so you can safely delete and
  rebuild images without affecting VM state, and to keep `images/` rsync-friendly
  for CI cache seeding.
  - `images/<name>.qcow2` — pre-built guest images produced in build phase.
  - `images/<name>-build/` — temporary Packer output directory used during builds.
  - `images/<name>-installer.iso` — cached Windows installer ISO used by rebuilds.
- `scripts/` — generated start and configure helper scripts for each VM.
- `<name>.utm/` — UTM bundle directory on macOS hosts.
- `<name>.qcow2` — libvirt/QEMU runtime disk on Linux/Windows hosts.

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

- `{{IMAGES_DIR_DISPLAY}}/<name>-build/` — Packer temp files (~10–30 GB)

Persistent VM artifacts (remove only when intentionally deleting a VM):

- `{{IMAGES_DIR_DISPLAY}}/<name>.qcow2` — pre-built guest image (~2–20 GB)
- `{{VM_DIR_DISPLAY}}/.tart/` — Tart VM store
- `{{VM_DIR_DISPLAY}}/<name>.utm/` — UTM bundle
- `{{VM_DIR_DISPLAY}}/<name>.qcow2` — runtime disk
- `{{VM_DIR_DISPLAY}}/scripts/start-<name>.sh` — POSIX start helper
- `{{VM_DIR_DISPLAY}}/scripts/start-<name>.ps1` — PowerShell start helper

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
