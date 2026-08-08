# nixos manual steps

- After first install (Btrfs with `@` root and `@nix` for `/nix` per `src/hosts/NixOS/hardware/disks.nix`): partition the disk, `mkfs.btrfs` on the root partition, `btrfs subvolume create @` and `btrfs subvolume create @nix`, mount `@` at `/mnt` and `@nix` at `/mnt/nix`, then run `nixos-install`. Generate hardware config: `sudo nixos-generate-config --dir /tmp/nixos-generate-config`. Compare with `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix` and merge host-specific facts (filesystem UUIDs, EFI `/boot`, swap, kernel modules, device paths). Uncomment the `/boot` vfat entry in `disks.nix` when merging. Rebuild to confirm no missing references.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud-setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open EasyEffects, add Limiter or Compressor under Effects > Output to cap volume. For presets: clone <https://github.com/Digitalone1/EasyEffects-Presets> into `~/.local/share/easyeffects/output/`.
- Verify CamillaDSP loopback: `arecord -l | grep Loopback`. If missing, reboot after `nucleus-apply`.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gff`, `-gl`, `-gp`, `-gpl`, `-gplf`, `-gs`, `-gst`, `-gsw` — git commands
- `-gs-pdf-opt-default`, `-gs-pdf-opt-ebook`, `-gs-pdf-opt-prepress`, `-gs-pdf-opt-printer`, `-gs-pdf-opt-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands
- `-v` — `nvim`

## nucleus commands

- `nucleus-ai` — manage AI models (sync, list, status, endpoint, config)
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-bump-lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- `nucleus-check-pwsh` — check PowerShell syntax
- `nucleus-check-sh` — check POSIX shell syntax
- `nucleus-cloud-setup` — configure cloud remotes and re-apply
- `nucleus-gc` — run Nix garbage collection; VM step keeps every manifest guest (enabled or not, any host) and manifest-referenced disks — use `nucleus-vm gc --gc-disabled` to narrow to enabled+current-host only
- `nucleus-gs-pdf-opt` — optimize PDF files with Ghostscript (keeps .bak backup by default; use `--rm-bak` to remove)
- `nucleus-audit-store` — print Nix store audit baseline metrics
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`. Requires `libvirtd` active (from `vms.nix`). Guest converge is automatic; run `nixos-rebuild switch` inside the guest for manual re-converge.
  - **macOS guest**: not automated (Apple EULA restricts redistribution).
  - **NixOS guest**: automatic; `nixos-generators` builds the image.
  - **Windows 11 guest**: ISO auto-downloaded (Fido-style); fallback `--windows-iso /path/to/Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>).
  - **Android guest** (LineageOS): libvirt/KVM; ADB at `localhost:22040`. Run `nucleus-vm android-config Android` without flags for the full guide.
    - **Google services (MindTheGapps)**: sideload in **LineageOS Recovery** via `nucleus-vm android-config Android --gapps` (recovery → **Advanced → Enter fastboot** → run `--gapps` → **Enable ADB** → sideload).
    - **First boot**: after `nucleus-vm reset Android`, boot **LineageOS Recovery**, run `--gapps`, then reboot. After Lineage boots, tap **Allow** on USB debugging, then run `--magisk`, `--root`, and `--fake-wifi` (booted system only).
    - **Magisk / root / fake Wi-Fi**: `nucleus-vm android-config Android --magisk`, then `--root`, then `--fake-wifi`. Re-run after userdata reset. Open the Magisk app after `--magisk` if prompted for environment fix.
    - **ADB unauthorized**: boot LineageOS, tap **Allow**, then `nucleus-vm android-config Android --adb-keys`.
- `nucleus-vm resize <id> <size>` — grow the writable runtime disk `data/<id>.qcow2` (grow-only; shrinking requires `--allow-shrink`)
- `nucleus-vm pack` — strip trivially regenerable artifacts (generated start/stop scripts, `src/<type>/overlay backing.qcow2` copies) so the tree copies as-is to another host; dry-run by default, `--force` performs
- `nucleus-vm unpack` — regenerate platform artifacts (start/stop scripts, libvirt domains) from `<id>.vm.json` descriptors after copying a packed tree
