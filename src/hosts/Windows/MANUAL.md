# windows manual steps

- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `%USERPROFILE%\.config\rclone\rclone.conf` first.
- Run `nucleus-cloud-setup` in PowerShell and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Run Equalizer APO configurator to select your playback device, then reboot.
- Launch Peace Equalizer APO, use Effects > Limiter sliders or pre-amplification to cap output.
- Run `camilladsp --list-devices` and update `src/modules/configs/camilladsp/configs/windows/config.yml` if the default device name doesn't match.
- Caddy local-CA trust runs automatically. If missing: run `caddy trust --address 127.0.0.1:2019` in an elevated PowerShell.
- Starship prompt is active in all shells. Requires a Nerd Font (configured automatically via `CaskaydiaCove Nerd Font`).

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
- `nucleus-bump-lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `-Sections winget,scoop,...` for specific sections
- `nucleus-check-pwsh` — check PowerShell syntax
- `nucleus-check-sh` — check POSIX shell syntax
- `nucleus-cloud-setup` — configure cloud remotes and re-apply
- `nucleus-gc` — run Nix garbage collection
- `nucleus-gs-pdf-opt` — optimize PDF files with Ghostscript (keeps .bak backup by default; use `--rm-bak` to remove)
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`. Requires QEMU (managed by Scoop). Guest converge is automatic; run `.\src\hosts\Windows\apply.ps1` inside the guest for manual re-converge.
  - **NixOS guest**: uses Packer (ISO auto-downloaded).
  - **Windows 11 guest**: ISO auto-resolved; fallback `-WindowsIso C:\path\to\Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>). Use `-Accelerator whpx` if Windows HyperVisor Platform is enabled. Run `start-<name>.ps1` in `%USERPROFILE%\virtual machines\`.
