# MacBook manual steps

- If `/nix` is missing before the first Nix install: run `nucleus-bootstrap`, reboot when prompted, then re-run bootstrap. `nucleus-apply` never modifies `/etc/synthetic.conf`.
- Configure Raycast database-only settings (see [raycast-manual-config.md](raycast-manual-config.md)): hotkeys (⌘Space, ⌥⌘C), search sensitivity, vim keybindings.
- Hide MiddleClick from the menu bar: hold ⌘ and drag the icon away until ✖️ appears. The icon reappears each time the app relaunches, so hide it again with ⌘-drag.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick.
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Grant Automation to the terminal running `nucleus-vm setup` for UTM imports.
- Allow full disk access for remote users: open System Settings → General → Sharing → Remote Login, click the **(i)** icon, then turn **Allow full disk access for remote users** on.
- Cloud mounts need two things in place; replicas and sync need neither. First, `nucleus-apply` must have completed. Check with `launchctl list | grep cloud`, which should list `local.cloud-mount.*` and `local.cloud-replica-scheduled-sync.*` agents. Second, the macFUSE file-system extension must be enabled; installing macFUSE does not enable it on its own. Turn it on in System Settings → General → Login Items & Extensions → **by category** → File System Extensions, where it is listed as **macFUSE**. Confirm it with `plutil -p "$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"`, which is the module list FSKit mounts through; neither `pluginkit -m -A -p com.apple.fskit.fsmodule` nor `systemextensionsctl list` ever lists macFUSE, so they cannot confirm this step. When a mount is refused with `File system extension not found`, `File system extension not enabled`, or a macFUSE "Unexpected error" alert, run `nucleus-cloud repair`, which restarts the FSKit daemon (`sudo killall fskitd`; SIP refuses `launchctl kickstart` on that daemon), clears the blocked mount markers, and restarts the affected mounts; a reboot clears it too. The System Settings toggle above only helps when macFUSE is missing from that list. Never run `pluginkit -a` on the macFUSE extension bundle by hand: macFUSE's installer already re-registers it on every attempt, and that re-registration is what drops it from FSKit's enabled list. Never approve the macFUSE **kernel extension**: every mount uses the FSKit backend (`-o backend=fskit`), which needs none. Mounts live at `~/clouds/<id>` as a real directory that `nucleus-apply` creates, and it must be empty for the mount to succeed, so keep data out of it (the `*Replica` paths are separate).
- NTFS read-write: launch Mounty, agree to the dialog, plug in an NTFS drive, then re-mount it via the Mounty menu-bar icon. If the drive mounts read-only (e.g. after Windows Fast Startup): unmount the drive, run `sudo ntfsfix /dev/diskXsY`, then reconnect the drive. Fallback: unmount and `sudo ntfs-3g -o backend=fskit /dev/diskXsY /Volumes/nucleus-ntfs`. NTFS read-write goes through the same macFUSE FSKit backend, so never approve the macFUSE kernel extension. The ntfs-3g binary is built automatically during `nucleus-apply`. If the build fails, see `/Library/Application Support/nucleus/logs/ntfs-3g-build.log` for the full output. Mounty's menu-bar icon uses the macOS 26 Control Center `NSStatusItem Visible com.mounty.app` gate. Mounty has no ⌘-drag hide and no hide preference. The `sudo ntfs-3g` fallback above is the only no-icon path. Mounty's app-native helper (`com.cu4uc.MountyHelper`) is an embedded Service-Management helper, which macOS 13+ does not let a script unregister: turn it off in Mounty's own settings if it is registered, and keep only our registry-driven launch agent. Do not re-enable the embedded helper.
- Open `battery.app` once to install `/usr/local/bin/battery`. No tray icon at boot (not a login item); the charge limit works headlessly: `battery maintain 80` installs the `com.battery.app` LaunchAgent.
- Sign in to the App Store so `mas` can provision Amphetamine.
- Apple Command Line Tools (CLT) are not required before, during, or after `nucleus-apply`. The install tree under `/Library/Developer/CommandLineTools` is removed on each apply when present (~1 GB). SIP-protected pkgutil receipts stay, so Software Update may still offer CLT installs. Nix provides `clang`/`clang++`/`ld.lld` via absolute store paths in `CC`/`CXX`/`LD`; `/usr/bin/clang` (xcrun shim) is never reached. If you see the xcrun dialog, confirm `nucleus-apply` completed and restart your shell session.
- Install Amphetamine Power Protect: copy script to `~/Library/Application Scripts/com.if.Amphetamine/` and sudoers to `/private/etc/sudoers.d/` (see upstream README). Re-run `nucleus-apply`.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open Equaliser once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions. Menu-bar-only app (no hide option, no auto-launch); never add a LaunchAgent for it.
- Run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone permission.
- OBS virtual camera: OBS 28 and later bundle the CoreMediaIO plugin and install it to `/Library/CoreMediaIO/Plug-Ins/DAL/` automatically on first launch. Open OBS, start the virtual camera once, then approve the system extension in System Settings → Privacy & Security (Extensions → Driver Extensions) and grant Camera permission. No declarative install is possible (SIP-protected path + user consent). The pinned `OBSProject.OBSStudio` 31.1.2 and the Homebrew `obs` cask already meet the ≥28 requirement.
- LuLu's menu bar icon is hidden declaratively (`noIconMode`); alerts and firewall rules are unaffected. To manage LuLu, reopen the app to show its preferences window.
- OrbStack's menu bar applet is enabled declaratively via macOS 26 Control Center `NSStatusItem Visible com.orbstack.orbstack`. To restore after manual toggle: System Settings → Menu Bar → OrbStack → **Allow in the Menu Bar**.
- Parsec has no menu bar icon hide option. If its icon ever appears, hide it per-session with ⌘-drag.
- Lock-screen wallpaper: `nucleus-apply` mirrors the desktop wallpaper onto the lock screen by rewriting the WallpaperKit store (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`), which is where macOS records the screen saver surface for the lock screen. If macOS denies the write, the apply logs a warning instead of failing. Fix it once by choosing **Photos** in System Settings → Wallpaper → Screen Saver and pointing it at `~/Pictures/wallpapers`, then lock the screen to confirm.
- Restart macOS to see managed Finder sidebar favorites.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.
- Nix commands may wait on a `nixpkgs-weekly/0.1` fetch from flakehub ("waiting for another Nix process" / "unpacking" lines). This comes from machine-level config (the global registry maps `nixpkgs` to flakehub; `/etc/nix/nix.conf` sets `extra-nix-path`), not from `src/flake.lock`. It is a one-time cold-cache cost; later runs are instant.
- Harness bridge (desktop reminders, remote approvals, and remote prompts for Cursor, VS Code Copilot Chat, opencode, and pi): the Hermes gateway owns the platform credentials and runs as the launchd user agent `org.nix-community.home.hermes-agent`, with the `harness-bridge` plugin enabled by `nucleus-apply`. Provision a channel once — seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN`, in your SOPS file — list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, turn that platform on in the gateway config (`platforms.<name>.enabled`), and re-run `nucleus-apply`. Notifications go to every channel in `nucleus-config get harness-notify.channels`; remove one there to mute it, or run `nucleus-config set harness-notify.enable false` to stop notifications on this machine. Reply `/harness approve <id>` or `/harness deny <id>` to answer a pending tool call, `/harness sessions` to list what is pending, and `/harness send <harness> <text>` to inject a prompt into a waiting session. An unanswered request asks locally instead, after `nucleus-config get harness-approval.timeout-seconds` (default 120 s), so the `timeout` on each hook in `~/.agents/hooks/harness-notify.json` and `~/.cursor/hooks.json` must stay larger. Every decision is appended to `~/Library/Application Support/nucleus/logs/harness-bridge.log`. All four harnesses can be driven remotely here; Cursor ignores remote prompts on Windows only.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gff`, `-gl`, `-gp`, `-gpl`, `-gplf`, `-gs`, `-gst`, `-gsw` — git commands
- `-optimize-pdf-default`, `-optimize-pdf-ebook`, `-optimize-pdf-prepress`, `-optimize-pdf-printer`, `-optimize-pdf-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands
- `-v` — `nvim`

## service management

- macOS launchd policy and SIP workarounds: `.agents/instructions/macos-service-hardening.instructions.md`.
- `nucleus-svc list` — list all nucleus-managed services with status
- `nucleus-svc restart <service>` — restart a service (recovery strategy in `macos-service-hardening.instructions.md`)
- Service watchdog runs every 5 minutes (`local.service-watchdog`). Check status with `launchctl list | grep service-watchdog`.
- To see if a service is running: `nucleus-svc status <service>` or `sudo launchctl print system/<plist-id>` (e.g. `sudo launchctl print system/org.nixos.local.ollama`).
- LiteLLM recovery: if `nucleus-svc litellm` is active but every `default` request fails with HTTP 429/500 (`Missing credentials` / `No deployments available`), the daemon was built with no API-key pairs, usually because `src/modules/env-catalog.nix` is out of sync with decrypted SOPS secrets. Confirm with `sudo launchctl print system/local.litellm | grep ProgramArguments`. If there are no `KEYFILE:ENVVAR` pairs, run `nucleus-apply` to rebuild, then `nucleus-svc restart litellm`. The build-time assertion in `ai.nix` fails eval fast if the catalog declares keys but none resolve.

## nucleus commands

- `nucleus-ai` — manage AI models (sync, list, status, endpoint, config)
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-update lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- Homebrew `masApps` (`suggestions.homebrew.masApps`) are warn-only and never enforced. Formula/cask versions are pinned by nix-homebrew tap commits in `flake.lock`, not `lockfile.json`. `nucleus-update lockfile --verify-installed` always warns for `suggestions`.
- `nucleus-check pwsh` — check PowerShell syntax
- `nucleus-check sh` — check POSIX shell syntax
- `nucleus-cloud setup` — configure cloud remotes and re-apply
- `nucleus-gc` — run Nix garbage collection (VM GC policy: `vm-management.instructions.md`)
- `nucleus-utils optimize-pdf` — optimize PDF files with Ghostscript (keeps .bak backup by default; use `--rm-bak` to remove)
- `nucleus-apply audit-store` — print Nix store audit baseline metrics
- `nucleus-apply health-check` — run health checks
- `nucleus-cloud sync` — pull cloud replicas
- `nucleus-cloud reset` — reset local replica state
- `nucleus-update` — update repository
- `nucleus-vm setup` — build and provision VMs from `src/modules/vms/VMs.json`
  - **macOS guest** (tart): automatic on Apple Silicon. Requires `brew install cirruslabs/cli/tart`. Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: automatic; `nixos-generators` builds QCOW2.
  - **Windows 11 guest**: ISO auto-downloaded (Mido on POSIX, Fido on Windows); pass `--windows-iso /path/to/Win11.iso` to skip.
  - **Android guest** (LineageOS): UTM preferences and guest audio workarounds are repo-managed. Workflow, flags, and UTM freeze recovery: `.agents/instructions/vm-management.instructions.md` (android-config, Android UTM freeze). Run `nucleus-vm android-config Android` without flags for step-by-step instructions.
- `nucleus-vm resize <id> <size>` — grow-only runtime disk; see `vm-management.instructions.md`
- `nucleus-vm pack` / `nucleus-vm unpack` — cross-host migration; see `vm-management.instructions.md`
