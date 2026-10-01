# Windows manual steps

Steps `nucleus-apply` cannot do. Everything else is already converged.

## apps

1. Equalizer APO: run the configurator to pick the playback device, then reboot.
2. Peace Equalizer APO: cap output with the Effects > Limiter sliders or with pre-amplification.
3. OBS virtual camera: start the virtual camera from OBS and it appears as a DirectShow device in other apps. `obs-virtualcam` ships inside the `OBSProject.OBSStudio` install, so there is nothing to install separately.
4. Chrome Remote Desktop Host is installed declaratively as `Google.ChromeRemoteDesktopHost` (WinGet). To accept connections, finish "Set up remote access" at <https://remotedesktop.google.com/access>. The installer owns the service; apply neither starts nor stops it.
5. Picard: sign in and add the AcoustID API key under Options.
6. Starship is active in every shell and needs a Nerd Font. Apply installs `DEVCOM.JetBrainsMonoNerdFont`, so select it as the terminal font.

## secrets and remotes

1. Generate `rclone_config_pass`: `openssl rand -hex 64` into `rclone_config_pass` in `src/secrets/users/<username>.yml`, commit, re-run `nucleus-apply`. Delete `%USERPROFILE%\.config\rclone\rclone.conf` first when unencrypted remotes exist.
2. Run `nucleus-cloud setup` in PowerShell and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.

## recovery

1. Caddy local-CA trust runs during apply. To redo it, run `caddy trust --address 127.0.0.1:2019` in an elevated PowerShell.

## speech to text

1. Transcribe a file: `whisper-cli -m "$env:LOCALAPPDATA\nucleus\models\ggml-base.en.bin" -f <audio-file>`.
2. Transcribe live: `whisper-stream -m "$env:LOCALAPPDATA\nucleus\models\ggml-base.en.bin"`. Add `--step 0` for discrete segments instead of a rolling window.
3. `whisper-stream` opens an SDL2 window; close it to stop. Run it from a terminal on the desktop: a PowerShell session outside the interactive desktop session has no microphone and captures nothing.

## harness bridge

Apply installs the `hermes-gateway` SCM service, enables the `harness-bridge` plugin, and deploys the hook entry points as `.cmd` shims in `%USERPROFILE%\.local\bin`. To provision a channel once: seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN` in your SOPS file, list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, set `platforms.<name>.enabled` in the gateway config, then re-run `nucleus-apply`.

Remote approvals are off by default: `nucleus-config set harness-approval.enable true` to enable them. `nucleus-config get harness-notify.channels` lists the notification channels; `nucleus-config set harness-notify.enable false` stops the bridge on this machine, and `nucleus-apply -NoUserStateParity` removes the shims entirely.

Cursor ignores remote prompts on Windows (upstream bug), so drive Cursor sessions from macOS or NixOS. The rules behind those switches and the `/harness` commands are in `.agents/instructions/agents-and-skills.instructions.md`.
