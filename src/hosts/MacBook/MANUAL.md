# macbook manual steps

## One-Time Configuration

- Configure Raycast database-only settings: see [raycast-manual-config.md](raycast-manual-config.md) for step-by-step guide. This includes the main hotkey (⌘Space), Clipboard History hotkey (⌥⌘C), search sensitivity, vim keybindings, and other advanced options that cannot be declaratively managed.
- **Menu bar icons**: AltTab, BetterDisplay, and LinearMouse are hidden automatically. To hide `MiddleClick`, hold `⌘`, drag its menu bar icon away until `✖️` appears, then release. Re-open MiddleClick while it is already running to show the icon again.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick (MiddleClick requires this to synthesize mouse button events).
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Open `fuse-t.app` once, then enable the `fuse-t` File System Extension in `System Settings > General > Login Items & Extensions > Extensions`.
- Open `battery.app` once so `/usr/local/bin/battery` is installed.
- Sign in to the App Store once so `mas` installs can provision Xcode and Amphetamine.
- Grant Automation permission to the shell or terminal app that runs `nucleus-vm-setup` so it can ask UTM to import `.utm` bundles automatically.
- Install Amphetamine Power Protect one time (upstream requires manual placement): copy the Power Protect script to `~/Library/Application Scripts/com.if.Amphetamine/` and the Power Protect sudoers file to `/private/etc/sudoers.d/` as documented at `https://raw.githubusercontent.com/x74353/Amphetamine/master/README.md`, then re-run `nucleus-apply`.
- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `~/.config/rclone/rclone.conf` first so the remotes are re-created with encryption.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.
- Open MusicBrainz Picard, then sign in with your MusicBrainz account in `Options > General`.
- In MusicBrainz Picard, add your AcoustID user API key in `Options > Fingerprinting`, then save.
- Open **Equaliser** once, then approve its virtual audio driver system extension in `System Settings > Privacy & Security > Extensions > Audio Extensions` (required after each macOS update that resets extension approval). It is automatically installed to `/Applications` by `nucleus-apply`.
- Open CamillaDSP once (CamillaDSP runs headlessly, so launch `camilladsp --version` in a terminal), then approve the **BlackHole** virtual audio driver system extension in `System Settings > Privacy & Security` (required after each macOS update that resets extension approval). Also grant Microphone permission to CamillaDSP in `System Settings > Privacy & Security > Microphone`.
- Finder sidebar favorites set by `nucleus apply` are visible only after restarting macOS (log out and back in, or reboot).

## accessible ports

- `https://localhost:8920` — Jellyfin HTTPS endpoint (Caddy local reverse proxy).
- `http://127.0.0.1:8096` — Jellyfin internal loopback HTTP API (automation upstream).
- `http://127.0.0.1:11434` — Ollama local API.
- `tcp/1234` — CamillaDSP websocket API (loopback, for camillagui-backend).
- `http://127.0.0.1:5005` — CamillaDSP web GUI.
- `tcp/5900` — macOS Screen Sharing / VNC (when enabled).
- `tcp/31022` — Linux builder SSH endpoint.

## HTTPS certificate trust (one-time)

- `nucleus-apply` now runs Caddy local-CA trust automatically for managed localhost HTTPS reverse proxies.
- If trust is still missing after apply, run `sudo caddy trust --address 127.0.0.1:2019` once.

## command shortcuts

- `-g` — run `git`.
- `-ga` — run `git add`.
- `-gb` — run `git branch`.
- `-gc` — run `git commit`.
- `-gca` — run `git commit --amend`.
- `-gcl` — run `git clone`.
- `-gco` — run `git checkout`.
- `-gd` — run `git diff`.
- `-gf` — run `git fetch`.
- `-gl` — run `git log --oneline --decorate --graph`.
- `-gst` — run `git status`.
- `-gp` — run `git push`.
- `-gpl` — run `git pull`.
- `-gs` — run `git status -sb`.
- `-gs-pdf-opt-default` — optimize PDFs with Ghostscript default profile.
- `-gs-pdf-opt-ebook` — optimize PDFs with Ghostscript ebook profile.
- `-gs-pdf-opt-prepress` — optimize PDFs with Ghostscript prepress profile.
- `-gs-pdf-opt-printer` — optimize PDFs with Ghostscript printer profile.
- `-gs-pdf-opt-screen` — optimize PDFs with Ghostscript screen profile.
- `-gsw` — run `git switch`.
- `-la` — run `eza -la`.
- `-ll` — run `eza -la`.
- `-ni` — run `bun install`.
- `-nr` — run `bun run`.
- `-nx` — run `bun x`.
- `-v` — open `nvim`.

## nucleus commands

- `nucleus-ai-sync` — run the managed AI model sync flow.
- `nucleus-apply` — run the managed apply flow.
- `nucleus-bootstrap` — run the managed bootstrap flow.
- `nucleus-bump-lockfile` — update all version pins in the consolidated lockfile (`src/lockfiles/lockfile.json`) from upstream sources; pass `--sections winget,scoop,...` to update specific sections.
- `nucleus-check-pwsh` — run PowerShell syntax checks.
- `nucleus-check-sh` — run POSIX shell syntax checks.
- `nucleus-cloud-setup` — configure required cloud remotes and re-run apply.
- `nucleus-gc` — run the managed Nix garbage-collection flow.
- `nucleus-health-check` — run the managed repository health checks.
- `nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nucleus-vm-setup` — build (if needed) and provision VMs declared in `src/modules/VMs.json`; run once per machine or when adding a VM.
  - **macOS guest** (tart): fully automatic on Apple Silicon when `type: "macOS"` exists in `VMs.json`; Packer Tart builds the VM via `src/vms/macos/packer.pkr.hcl`. Requires `tart` (installed via `brew install cirruslabs/cli/tart`). Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: fully automatic; `nixos-generators` builds the QCOW2 image (no extra tools needed).
  - **Windows 11 guest**: ISO is auto-downloaded on first run via Mido on POSIX hosts and Fido on Windows hosts; pass `--windows-iso /path/to/Win11.iso` to skip downloader resolution.
