# macbook manual steps

- Configure Raycast database-only settings (see [raycast-manual-config.md](raycast-manual-config.md)): main hotkey (⌘Space), Clipboard History hotkey (⌥⌘C), search sensitivity, vim keybindings.
- Hide MiddleClick from the menu bar: hold ⌘, drag icon away until ✖️ appears. Re-open to show the icon again.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick.
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Grant Automation to the terminal running `nucleus-vm-setup` for UTM imports.
- Open `fuse-t.app` once, then enable the extension in System Settings > General > Login Items & Extensions > Extensions.
- NTFS read-write: launch Mounty, agree to the dialog, plug in an NTFS drive, then re-mount it via the Mounty menu-bar icon. If the drive mounts read-only (e.g. after Windows Fast Startup): unmount the drive, run `sudo ntfsfix /dev/diskXsY`, then reconnect the drive. Fallback: unmount and `sudo ntfs-3g /dev/diskXsY /path/to/mountpoint`. The ntfs-3g binary is built automatically during `nucleus-apply`.
- Open `battery.app` once to install `/usr/local/bin/battery`.
- Sign in to the App Store so `mas` can provision Xcode and Amphetamine.
- Install Amphetamine Power Protect: copy script to `~/Library/Application Scripts/com.if.Amphetamine/` and sudoers to `/private/etc/sudoers.d/` (see upstream README). Re-run `nucleus-apply`.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud-setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open Equaliser once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions.
- Run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone permission.
- Restart macOS to see managed Finder sidebar favorites.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gl`, `-gp`, `-gpl`, `-gs`, `-gst`, `-gsw` — git commands
- `-gs-pdf-opt-default`, `-gs-pdf-opt-ebook`, `-gs-pdf-opt-prepress`, `-gs-pdf-opt-printer`, `-gs-pdf-opt-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-ni` — `bun install`
- `-nr` — `bun run`
- `-nx` — `bun x`
- `-v` — `nvim`

## service management

- `nucleus-svc list` — list all nucleus-managed services with status
- `nucleus-svc restart <service>` — restart a service:
  1. If stuck (EX_CONFIG / "waiting" / "spawn scheduled"): full `bootout+bootstrap` recovery.
  2. If running: SIGTERM for graceful shutdown, then up to 5s wait, then `bootout+bootstrap` as safety net.
  3. The final `bootout` sends SIGKILL if the process is still alive — designed to clear launchd exit-code memory so services with non-retryable exit codes (EX_CONFIG, code 78) can start again.
- Service watchdog runs every 5 minutes (`local.service-watchdog`): detects services stuck in non-running states and recovers them automatically. Check status with `launchctl list | grep service-watchdog`.
- To see if a service is running: `nucleus-svc status <service>` or `sudo launchctl print system/<plist-id>` (e.g. `sudo launchctl print system/org.nixos.local.ollama`).

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
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm-setup` — build and provision VMs from `src/modules/VMs.json`
  - **macOS guest** (tart): automatic on Apple Silicon. Requires `brew install cirruslabs/cli/tart`. Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: automatic; `nixos-generators` builds QCOW2.
  - **Windows 11 guest**: ISO auto-downloaded (Mido on POSIX, Fido on Windows); pass `--windows-iso /path/to/Win11.iso` to skip.
