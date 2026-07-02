# nixos manual steps

- After first install, generate hardware config: `sudo nixos-generate-config --dir /tmp/nixos-generate-config`. Compare with `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix` and copy host-specific facts (filesystem UUIDs, swap, kernel modules, device paths). Rebuild to confirm no missing references.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud-setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open EasyEffects, add Limiter or Compressor under Effects > Output to cap volume. For presets: clone <https://github.com/Digitalone1/EasyEffects-Presets> into `~/.local/share/easyeffects/output/`.
- Verify CamillaDSP loopback: `arecord -l | grep Loopback`. If missing, reboot after `nucleus-apply`.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gl`, `-gp`, `-gpl`, `-gs`, `-gst`, `-gsw` — git commands
- `-gs-pdf-opt-default`, `-gs-pdf-opt-ebook`, `-gs-pdf-opt-prepress`, `-gs-pdf-opt-printer`, `-gs-pdf-opt-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-ni` — `bun install`
- `-nr` — `bun run`
- `-nx` — `bun x`
- `-v` — `nvim`

## nucleus commands

- `nucleus-ai-sync` — sync AI models
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-bump-lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- `nucleus-check-pwsh` — check PowerShell syntax
- `nucleus-check-sh` — check POSIX shell syntax
- `nucleus-cloud-setup` — configure cloud remotes and re-apply
- `nucleus-gc` — run Nix garbage collection
- `nucleus-gs-pdf-opt` — optimize PDF files with Ghostscript (creates .bak backup)

Also available as right-click context menu entries: in Nautilus (Scripts → optimize pdf (default/ebook/prepress/printer/screen)) and Dolphin (right-click PDF → optimize pdf (default/ebook/prepress/printer/screen)).
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm-setup` — build and provision VMs from `src/modules/VMs.json`. Requires `libvirtd` active (from `vms.nix`). Guest converge is automatic; run `nixos-rebuild switch` inside the guest for manual re-converge.
  - **macOS guest**: not automated (Apple EULA restricts redistribution).
  - **NixOS guest**: automatic; `nixos-generators` builds the image.
  - **Windows 11 guest**: ISO auto-downloaded (Fido-style); fallback `--windows-iso /path/to/Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>).
