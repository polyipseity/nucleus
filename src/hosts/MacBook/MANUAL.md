# MacBook manual steps

Steps `nucleus-apply` cannot do. Everything else is already converged.

## system

1. `/nix` missing before the first Nix install: run `nucleus-bootstrap`, reboot when prompted, then re-run bootstrap. Apply never edits `/etc/synthetic.conf`.
2. Enable the macFUSE file system extension: System Settings > General > Login Items & Extensions > by category > File System Extensions > macFUSE. Confirm with `plutil -p "$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"`; `pluginkit` and `systemextensionsctl` never list macFUSE. When a mount is refused with "File system extension not enabled" or an FSKit "Unexpected error", run `nucleus-cloud repair`, which restarts `fskitd`, clears the blocked markers, and restarts the mounts.
3. Never approve the macFUSE kernel extension: every mount uses the FSKit backend (`-o backend=fskit`). Never run `pluginkit -a` on macFUSE either; its installer re-registers the extension on every attempt, and that re-registration is what drops it from the FSKit list.
4. NTFS read-write: launch Mounty, agree to the dialog, plug in the drive, then remount from the menu-bar icon. Read-only after Windows Fast Startup: unmount, `sudo ntfsfix /dev/diskXsY`, reconnect. Fallback: `sudo ntfs-3g -o backend=fskit /dev/diskXsY /Volumes/nucleus-ntfs`. A failed ntfs-3g build logs to `/Library/Application Support/nucleus/logs/ntfs-3g-build.log`.
5. Mounty's embedded `com.cu4uc.MountyHelper` cannot be unregistered by a script on macOS 13+: turn it off in Mounty's settings so only the registry-driven launch agent remains.
6. Hide MiddleClick from the menu bar with command-drag until the icon shows the ✖️ mark. The icon returns each time the app relaunches. Parsec has no hide option, so hide it per session the same way.
7. Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick, and Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
8. Grant Automation to the terminal that runs `nucleus-vm setup`, so UTM imports can be approved.
9. Allow full disk access for remote users: System Settings > General > Sharing > Remote Login > (i) > Allow full disk access for remote users.
10. LuLu's icon is hidden through `noIconMode`, so reopening LuLu restores its preferences window.

## macOS settings with no API

1. Charge limit: set System Settings > Battery > (i) > Charge Limit to 80 % once. Apple exposes no `pmset` key, profile, or CLI for it, so apply cannot set it. Apply already converges the firmware gate with `battery maintain 80`; the native limit is the backstop when that helper breaks. Confirm the firmware gate with `sudo /usr/local/co.palokaj.battery/smc -k CHWA -r` (`01` = engaged) and the result with `pmset -g batt` (`80%; AC attached; not charging`).
2. Finder sidebar favorites: apply refreshes `sharedfilelistd` and `cfprefsd` itself, so only log out and back in when apply reported a sidebar failure.

## apps

1. Sign in to the App Store so `mas` can provision Amphetamine.
2. Install Amphetamine Power Protect per its upstream README: copy the script to `~/Library/Application Scripts/com.if.Amphetamine/` and the sudoers file to `/private/etc/sudoers.d/`, then re-run `nucleus-apply`. The install toggle itself is declarative (`Enable Power Protect Install`).
3. Picard: sign in and add the AcoustID API key under Options.
4. Equaliser: open it once, then approve its audio driver in System Settings > Privacy & Security > Extensions > Audio Extensions. It is menu-bar-only: never add a LaunchAgent.
5. CamillaDSP: run `camilladsp --version`, then approve BlackHole in System Settings > Privacy & Security and grant Microphone.
6. OBS virtual camera: start the virtual camera once, then approve the Driver Extension under Privacy & Security and grant Camera. OBS 28+ installs the CoreMediaIO plugin on first launch, so nothing needs installing by hand.
7. Stats ships `eu.exelban.Stats.LaunchAtLogin`, an embedded SMAppService helper no script can unregister. If two Stats processes start at login, open Stats > Open application settings and turn Start at login off. Do not run `sfltool resetbtm`, which clears login items for every app.
8. OrbStack's menu bar applet is toggled declaratively through the macOS 26 Control Center gate. To restore it after a manual toggle: System Settings > Menu Bar > OrbStack > Allow in the Menu Bar.

## secrets and remotes

1. Generate `rclone_config_pass`: `openssl rand -hex 64` into `rclone_config_pass` in `src/secrets/users/<username>.yml`, commit, re-run `nucleus-apply`. Delete `~/.config/rclone/rclone.conf` first when unencrypted remotes exist.
2. Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.

## recovery

1. Caddy local-CA trust runs during apply. To redo it: `sudo caddy trust --address 127.0.0.1:2019`.
2. Lock-screen wallpaper: apply rewrites the WallpaperKit store and warns when macOS denies the write. To fix it by hand, choose Photos in System Settings > Wallpaper > Screen Saver, point it at `~/Pictures/wallpapers`, then lock the screen to confirm.
3. LiteLLM returning HTTP 429/500 (`Missing credentials`, `No deployments available`) on every `default` request means the daemon was built with no `KEYFILE:ENVVAR` pairs, usually because `src/modules/lib/env-secrets.nix` is out of sync with the decrypted SOPS secrets. Check `sudo launchctl print system/local.litellm | grep ProgramArguments`, then run `nucleus-apply` and `nucleus-svc restart litellm`. `ai.nix` fails eval first when the catalog declares keys that resolve to nothing.

## speech to text

1. Transcribe a file: `whisper-cli -m "$HOME/Library/Application Support/nucleus/models/ggml-base.en.bin" -f <audio-file>`.
2. Transcribe live: `whisper-stream -m "$HOME/Library/Application Support/nucleus/models/ggml-base.en.bin"`. Add `--step 0` for discrete segments instead of a rolling window.
3. `whisper-stream` opens an SDL2 window; close it to stop. It needs Microphone permission for the terminal, which prompts on first capture.

## harness bridge

Apply installs the `harness-bridge` plugin. To provision a channel once: seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN` in your SOPS file, list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, set `platforms.<name>.enabled` in the gateway config, then re-run `nucleus-apply`.

Remote approvals are off by default: `nucleus-config set harness-approval.enable true` to enable them. `nucleus-config get harness-notify.channels` lists the notification channels; `nucleus-config set harness-notify.enable false` stops the bridge on this machine.

The rules behind those switches and the `/harness` commands are in `.agents/instructions/agents-and-skills.instructions.md`.
