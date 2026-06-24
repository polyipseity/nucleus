# macbook manual steps

## One-Time Configuration

- Configure Raycast database-only settings (see [raycast-manual-config.md](raycast-manual-config.md)): main hotkey (⌘Space), Clipboard History (⌥⌘C), search sensitivity, vim keybindings.
- Hide MiddleClick from the menu bar: hold ⌘, drag icon away until ✖️ appears. Re-open to show the icon again.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick.
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Grant Automation to the terminal running `nucleus-vm-setup` for UTM imports.
- Open `fuse-t.app` once, then enable the extension in System Settings > General > Login Items & Extensions > Extensions.
- Open `battery.app` once to install `/usr/local/bin/battery`.
- Sign in to the App Store so `mas` can provision Xcode and Amphetamine.
- Install Amphetamine Power Protect: copy script to `~/Library/Application Scripts/com.if.Amphetamine/` and sudoers to `/private/etc/sudoers.d/` (see upstream README). Re-run `nucleus-apply`.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud-setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open Equaliser once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions.
- Run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone permission.
- Restart macOS to see managed Finder sidebar favorites.



## HTTPS certificate trust (one-time)

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
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm-setup` — build and provision VMs from `src/modules/VMs.json`
  - **macOS guest** (tart): automatic on Apple Silicon. Requires `brew install cirruslabs/cli/tart`. Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: automatic; `nixos-generators` builds QCOW2.
  - **Windows 11 guest**: ISO auto-downloaded (Mido on POSIX, Fido on Windows); pass `--windows-iso /path/to/Win11.iso` to skip.
