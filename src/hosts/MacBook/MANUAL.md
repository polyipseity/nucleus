# macbook manual steps

- Configure Raycast database-only settings (see [raycast-manual-config.md](raycast-manual-config.md)): main hotkey (⌘Space), Clipboard History hotkey (⌥⌘C), search sensitivity, vim keybindings.
- Hide MiddleClick from the menu bar: hold ⌘, drag icon away until ✖️ appears. Re-open to show the icon again.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick.
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Grant Automation to the terminal running `nucleus-vm setup` for UTM imports.
- **Allow full disk access for remote users**: Open System Settings → General → Sharing → Remote Login → click the **(i)** icon → toggle **Allow full disk access for remote users** to **On**.
- Open `fuse-t.app` once, then enable the extension in System Settings > General > Login Items & Extensions > Extensions.
- NTFS read-write: launch Mounty, agree to the dialog, plug in an NTFS drive, then re-mount it via the Mounty menu-bar icon. If the drive mounts read-only (e.g. after Windows Fast Startup): unmount the drive, run `sudo ntfsfix /dev/diskXsY`, then reconnect the drive. Fallback: unmount and `sudo ntfs-3g /dev/diskXsY /path/to/mountpoint`. The ntfs-3g binary is built automatically during `nucleus-apply`. If the build fails, see `/Users/Shared/nucleus/logs/ntfs-3g-build.log` for the full output.
- Open `battery.app` once to install `/usr/local/bin/battery`.
- Sign in to the App Store so `mas` can provision Amphetamine.
- Apple Command Line Tools (CLT) are not required before, during, or after `nucleus-apply`. The Nix LLVM toolchain provides `clang`/`clang++`/`ld.lld` via absolute store paths in `CC`/`CXX`/`LD` — no PATH-based resolution occurs, so `/usr/bin/clang` (the xcrun shim) is never reached. If you see the xcrun dialog, check that `nucleus-apply` completed successfully and restart your shell session to pick up the updated environment.
- Install Amphetamine Power Protect: copy script to `~/Library/Application Scripts/com.if.Amphetamine/` and sudoers to `/private/etc/sudoers.d/` (see upstream README). Re-run `nucleus-apply`.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud-setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open Equaliser once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions.
- Run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone permission.
- Restart macOS to see managed Finder sidebar favorites.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.
- Nix commands may wait on a `nixpkgs-weekly/0.1` fetch from flakehub (multiple "waiting for another Nix process" or "unpacking" lines). This is machine-level config — the global registry maps `nixpkgs` to flakehub and `/etc/nix/nix.conf` sets `extra-nix-path` — not part of `src/flake.lock`. It is a one-time cold-cache cost; later runs are instant.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gff`, `-gl`, `-gp`, `-gpl`, `-gplf`, `-gs`, `-gst`, `-gsw` — git commands
- `-gs-pdf-opt-default`, `-gs-pdf-opt-ebook`, `-gs-pdf-opt-prepress`, `-gs-pdf-opt-printer`, `-gs-pdf-opt-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands
- `-v` — `nvim`

## service management

- macOS GUI env vars: propagated at activation time via `macos-gui-env-path`
  (src/modules/macos.nix), which runs `launchctl setenv` for all managed vars
  and `launchctl config user path` for LaunchServices PATH. A one-shot
  `gui-env` LaunchAgent provides login-time coverage before the first activation.
  After first `nucleus-apply`, a reboot is required for `launchctl config user
path` to take effect (though it is known to be unreliable — see
  [nix-darwin#1080](https://github.com/nix-darwin/nix-darwin/issues/1080)).
  Verify with:
  `/usr/libexec/PlistBuddy -c 'Print PathEnvironmentVariable' /private/var/db/com.apple.xpc.launchd/config/user.plist`
- `nucleus-svc list` — list all nucleus-managed services with status
- `nucleus-svc restart <service>` — restart a service:
  1. If stuck (EX_CONFIG / "waiting" / "spawn scheduled"): full `bootout+bootstrap` recovery.
  2. If running: SIGTERM for graceful shutdown, then up to 5s wait, then `bootout+bootstrap` as safety net.
  3. The final `bootout` sends SIGKILL if the process is still alive — designed to clear launchd exit-code memory so services with non-retryable exit codes (EX_CONFIG, code 78) can start again.
- Service watchdog runs every 5 minutes (`local.service-watchdog`): detects services stuck in non-running states and recovers them automatically. Check status with `launchctl list | grep service-watchdog`.
- To see if a service is running: `nucleus-svc status <service>` or `sudo launchctl print system/<plist-id>` (e.g. `sudo launchctl print system/org.nixos.local.ollama`).
- macOS 26+ SIP blocks unsigned Nix store binaries for system launchd daemons with non-root `UserName` (exit 78 / EX_CONFIG at boot). All MacBook daemons use `ProgramArguments = ["/bin/sh", "-c", "exec <nix-path>"]` — Apple-signed `/bin/sh` passes SIP gate. The service watchdog (`local.service-watchdog`) recovers any services that get stuck at boot.

## nucleus commands

- `nucleus-ai` — manage AI models (sync, list, status, endpoint, config)
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-bump-lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- `nucleus-check-pwsh` — check PowerShell syntax
- `nucleus-check-sh` — check POSIX shell syntax
- `nucleus-cloud-setup` — configure cloud remotes and re-apply
- `nucleus-gc` — run Nix garbage collection
- `nucleus-gs-pdf-opt` — optimize PDF files with Ghostscript (keeps .bak backup by default; use `--rm-bak` to remove)
- `nucleus-health-check` — run health checks
- `nucleus-replica-sync` — pull cloud replicas
- `nucleus-replica-reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`
  - **macOS guest** (tart): automatic on Apple Silicon. Requires `brew install cirruslabs/cli/tart`. Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: automatic; `nixos-generators` builds QCOW2.
  - **Windows 11 guest**: ISO auto-downloaded (Mido on POSIX, Fido on Windows); pass `--windows-iso /path/to/Win11.iso` to skip.
  - **Android guest** (LineageOS): requires UTM's global renderer backend to be **ANGLE (OpenGL)** (pref `QEMURendererBackend = 1`), otherwise the UI freezes or never appears after boot. The pref is provisioned automatically by `nucleus-apply` (activation script `macos-set-utm-renderer.sh`), so no manual UTM settings change is needed. See [LineageOS on UTM wiki](https://wiki.lineageos.org/utms/utm-vm-on-apple-silicon-mac) and [UTM issue #378](https://github.com/utmapp/UTM/issues/378).
