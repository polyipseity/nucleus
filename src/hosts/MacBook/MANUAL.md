# MacBook manual steps

- If `/nix` is missing before the first Nix install: run `nucleus-bootstrap`, reboot when prompted, then re-run bootstrap. `nucleus-apply` never modifies `/etc/synthetic.conf`.
- Configure Raycast database-only settings (see [raycast-manual-config.md](raycast-manual-config.md)): main hotkey (⌘Space), Clipboard History hotkey (⌥⌘C), search sensitivity, vim keybindings.
- Hide MiddleClick from the menu bar: hold ⌘, drag the icon away until ✖️ appears. The icon returns whenever the app is relaunched — hide it again with ⌘-drag.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick. The `osascript System Events` login-item convergence (`macos-configure-app-autostart.sh`) also needs Accessibility on first run (UI scripting) to add/remove login items; if login items are not applied, grant the terminal/runner Accessibility and re-run `nucleus-apply`.
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Grant Automation to the terminal running `nucleus-vm setup` for UTM imports.
- **Allow full disk access for remote users**: Open System Settings → General → Sharing → Remote Login → click the **(i)** icon → toggle **Allow full disk access for remote users** to **On**.
- **Cloud mounts require two prerequisites** (replicas/sync do not need FUSE-T): (1) a successful `nucleus-apply` so the current generation is active — verify with `launchctl list | grep cloud` (expect `local.cloud-mount.*` and `local.cloud-replica-scheduled-sync.*` agents), and (2) the FUSE-T FSKit system extension **activated**, not merely installed. To activate: open `fuse-t.app` once, then go to System Settings → General → Login Items & Extensions → Extensions → File System Extensions, and enable **fuse-t** (the `FskitSrvModule` FSKit module). Confirm with `systemextensionsctl list` — the fuse-t extension must show `activated enabled`. Until it is activated, `rclone mount` hangs on the FUSE handshake and unmounts. Run `nucleus-cloud setup` to configure remotes (`rclone config`) for GoogleDrive, iCloud, and OneDrive.
- NTFS read-write: launch Mounty, agree to the dialog, plug in an NTFS drive, then re-mount it via the Mounty menu-bar icon. If the drive mounts read-only (e.g. after Windows Fast Startup): unmount the drive, run `sudo ntfsfix /dev/diskXsY`, then reconnect the drive. Fallback: unmount and `sudo ntfs-3g /dev/diskXsY /path/to/mountpoint`. The ntfs-3g binary is built automatically during `nucleus-apply`. If the build fails, see `/Library/Application Support/nucleus/logs/ntfs-3g-build.log` for the full output. Mounty's menu-bar icon is enabled declaratively via the macOS 26 Control Center `NSStatusItem Visible com.mounty.app` gate — it has no ⌘-drag support and no hide preference, and it is the app's only control surface (remount trigger + state color). The `sudo ntfs-3g` fallback above is the only no-icon path. Mounty's app-native helper (`com.cu4uc.MountyHelper`) is neutralized by the same autostart convergence (`macos-configure-app-autostart.sh`), so only our registry-driven login item remains — do not re-enable the embedded helper.
- Open `battery.app` once to install `/usr/local/bin/battery`. The tray icon appears only when the app is opened manually — it is not a login item, so nothing shows at boot. The charge limit keeps working headlessly: `battery maintain 80` installs the `com.battery.app` LaunchAgent.
- Sign in to the App Store so `mas` can provision Amphetamine.
- Apple Command Line Tools (CLT) are not required before, during, or after `nucleus-apply`. The install tree under `/Library/Developer/CommandLineTools` is removed on each apply when present (~1 GB). SIP-protected pkgutil receipts are not removed — Software Update may still offer CLT installs. The Nix LLVM toolchain provides `clang`/`clang++`/`ld.lld` via absolute store paths in `CC`/`CXX`/`LD` — no PATH-based resolution occurs, so `/usr/bin/clang` (the xcrun shim) is never reached. If you see the xcrun dialog, check that `nucleus-apply` completed successfully and restart your shell session to pick up the updated environment.
- Install Amphetamine Power Protect: copy script to `~/Library/Application Scripts/com.if.Amphetamine/` and sudoers to `/private/etc/sudoers.d/` (see upstream README). Re-run `nucleus-apply`.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open Equaliser once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions. Equaliser's menu-bar icon is its only UI (menu-bar-only app, no hide option, no launch-at-login mechanism) — the app is not auto-launched, so the icon stays absent by default; never add a LaunchAgent for it.
- Run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone permission.
- OBS virtual camera: OBS 28+ bundles the CoreMediaIO plugin and installs it to `/Library/CoreMediaIO/Plug-Ins/DAL/` automatically on first launch. Open OBS, start the virtual camera once, then approve the system extension in System Settings → Privacy & Security (Extensions → Driver Extensions) and grant Camera permission. No declarative install is possible (SIP-protected path + user consent). The OBS ≥28 floor is already satisfied by the pinned `OBSProject.OBSStudio` 31.1.2 and Homebrew `obs` cask.
- LuLu's menu bar icon is hidden declaratively (`noIconMode`); alerts and firewall rules are unaffected. To manage LuLu (enable/disable, rules, profiles, quit), reopen the app to show its preferences window.
- OrbStack's menu bar applet is enabled declaratively via the macOS 26 Control Center `NSStatusItem Visible com.orbstack.orbstack` gate (macOS-level, no app preference exists). To restore it after a manual toggle: System Settings → Menu Bar → find OrbStack → turn on **Allow in the Menu Bar**.
- Parsec has no menu bar icon hide option. If its icon ever appears, hide it per-session with ⌘-drag.
- Restart macOS to see managed Finder sidebar favorites.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.
- Nix commands may wait on a `nixpkgs-weekly/0.1` fetch from flakehub (multiple "waiting for another Nix process" or "unpacking" lines). This is machine-level config — the global registry maps `nixpkgs` to flakehub and `/etc/nix/nix.conf` sets `extra-nix-path` — not part of `src/flake.lock`. It is a one-time cold-cache cost; later runs are instant.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gff`, `-gl`, `-gp`, `-gpl`, `-gplf`, `-gs`, `-gst`, `-gsw` — git commands
- `-optimize-pdf-default`, `-optimize-pdf-ebook`, `-optimize-pdf-prepress`, `-optimize-pdf-printer`, `-optimize-pdf-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands
- `-v` — `nvim`

## service management

- macOS GUI env, launchd daemon policy, and SIP workarounds: `.agents/instructions/macos-service-hardening.instructions.md`.
- `nucleus-svc list` — list all nucleus-managed services with status
- `nucleus-svc restart <service>` — restart a service (recovery strategy in `macos-service-hardening.instructions.md`)
- Service watchdog runs every 5 minutes (`local.service-watchdog`). Check status with `launchctl list | grep service-watchdog`.
- To see if a service is running: `nucleus-svc status <service>` or `sudo launchctl print system/<plist-id>` (e.g. `sudo launchctl print system/org.nixos.local.ollama`).
- LiteLLM recovery: if `nucleus-svc litellm` is active but every `default` request fails with HTTP 429/500 (`Missing credentials` / `No deployments available`), the daemon was built with no API-key pairs. This happens when `src/modules/ai/key-catalog.generated.nix` is out of sync with the decrypted SOPS secrets (e.g. after editing `src/secrets/system.yml` without re-applying). Confirm with `sudo launchctl print system/local.litellm | grep ProgramArguments` — if there are no `KEYFILE:ENVVAR` pairs, run `nucleus-apply` to regenerate the catalog from the decrypted secrets, then `nucleus-svc restart litellm`. The build-time assertion in `ai.nix` fails eval fast if the catalog declares keys but none resolve, so a stale catalog surfaces at apply time rather than as a runtime 429.

## nucleus commands

- `nucleus-ai` — manage AI models (sync, list, status, endpoint, config)
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-update lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- Homebrew `masApps` (`suggestions.homebrew.masApps`) are warn-only — never enforced. Formula/cask versions are pinned by nix-homebrew tap commits in `flake.lock`, not `lockfile.json`. `nucleus-update lockfile --verify-installed` always warns for `suggestions`.
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
- `nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`
  - **macOS guest** (tart): automatic on Apple Silicon. Requires `brew install cirruslabs/cli/tart`. Start with `tart run MacBook [--no-graphics]`.
  - **NixOS guest**: automatic; `nixos-generators` builds QCOW2.
  - **Windows 11 guest**: ISO auto-downloaded (Mido on POSIX, Fido on Windows); pass `--windows-iso /path/to/Win11.iso` to skip.
  - **Android guest** (LineageOS): UTM preferences and guest audio workarounds are repo-managed. Workflow, flags, and UTM freeze recovery: `.agents/instructions/vm-management.instructions.md` (android-config, Android UTM freeze). Run `nucleus-vm android-config Android` without flags for step-by-step instructions.
- `nucleus-vm resize <id> <size>` — grow-only runtime disk; see `vm-management.instructions.md`
- `nucleus-vm pack` / `nucleus-vm unpack` — cross-host migration; see `vm-management.instructions.md`
