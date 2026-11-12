# Windows manual steps

Steps `nucleus-apply` cannot do. Everything else is already converged.

## system

1. pi reports its sandbox state through the `sandbox` status indicator: `SANDBOX: srt` inside the srt sandbox and `SANDBOX: NONE (unsandboxed)` outside it. Run `/sandbox-status` for the evidence, mode, resolved `rm`, `shell-safe-rm`/`rip` presence, and the `safe-delete` filter's `unproven` setting. The unsandboxed warning is emitted once per process.

## apps

1. OBS virtual camera: start the virtual camera from OBS and it appears as a DirectShow device in other apps. `obs-virtualcam` ships inside the `OBSProject.OBSStudio` install, so there is nothing to install separately.
2. Chrome Remote Desktop Host is installed declaratively as `Google.ChromeRemoteDesktopHost` (WinGet). To accept connections, finish "Set up remote access" at <https://remotedesktop.google.com/access>. The installer owns the service; apply neither starts nor stops it.
3. Picard: sign in and add the AcoustID API key under Options.
4. Starship is active in every shell and needs a Nerd Font. Apply installs `DEVCOM.JetBrainsMonoNerdFont`, so select it as the terminal font.

## audio processing

1. CamillaDSP captures the default playback device in WASAPI loopback, so this host needs two playback endpoints: applications play into the default one, which CamillaDSP captures, and the processed audio goes to the other. With a single output there is nowhere for the unprocessed stream to go, and `camilladsp-heartbeat` logs a warning instead of feeding the output back into the capture. Set the spare endpoint (HDMI or an unused output) as the default playback device; the shipped configs leave both devices `null` so the heartbeat picks them. The heartbeat is the only writer of those configs: editing them in camillagui binds playback and capture to the same endpoint, which the heartbeat refuses to push, so the daemon keeps the last config it accepted.

## virtualization

1. Apply enables the Hyper-V optional feature, then reboot before running `vagrant up --provider hyperv`, because apply cannot restart the machine itself. Hyper-V is unavailable on Windows Home, so a Home host fails that step with a DISM "feature name is unknown" error and needs an upgrade to Pro.

## secrets and remotes

1. Generate `rclone_config_pass`: `openssl rand -hex 64` into `rclone_config_pass` in `src/secrets/users/<username>.yml`, commit, re-run `nucleus-apply`. Delete `%USERPROFILE%\.config\rclone\rclone.conf` first when unencrypted remotes exist.
2. Run `nucleus-cloud setup` in PowerShell and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.

## recovery

1. Caddy local-CA trust runs during apply. To redo it, run `caddy trust --address 127.0.0.1:2019` in an elevated PowerShell.

## speech to text

1. Transcribe a file: `whisper-cli -m "$env:LOCALAPPDATA\nucleus\models\ggml-base.en.bin" -f <audio-file>`.
2. Transcribe live: `whisper-stream -m "$env:LOCALAPPDATA\nucleus\models\ggml-base.en.bin"`. Add `--step 0` for discrete segments instead of a rolling window.
3. `whisper-stream` opens an SDL2 window; close it to stop. Run it from a terminal on the desktop: a PowerShell session outside the interactive desktop session has no microphone and captures nothing.
4. Clean a recording: `deep-filter -m "$env:LOCALAPPDATA\nucleus\models\DeepFilterNet3_onnx.tar.gz" -o out.wav in.wav`.

## harness bridge

Apply installs the `hermes-gateway` SCM service, enables the `harness-bridge` plugin, and deploys the hook entry points as `.cmd` shims in `%USERPROFILE%\.local\bin`. To provision a channel once: seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN` in your SOPS file, list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, set `platforms.<name>.enabled` in the gateway config, then re-run `nucleus-apply`.

Approvals are asked in the terminal by default (`harness-approval.sources` is `["prompt"]`); `nucleus-config set harness-approval.sources '["prompt","hermes"]'` adds the remote channel, and `harness-approval.timeout-seconds.<source>` bounds each wait, `0` meaning until answered. `nucleus-config get harness-notify.channels` lists the notification channels; `nucleus-config set harness-notify.enable false` stops the bridge on this machine, and `nucleus-apply -NoUserStateParity` removes the shims entirely. After an apply, trigger one deletion and confirm the approval prompt waits for Enter rather than accepting a single keypress: it reads `CONIN$` directly, so no unattended run can answer it, and `settings.unproven` defaults to `ask`, which puts that read on the default path for every deletion a harness runs on Windows.

Cursor ignores remote prompts on Windows (upstream bug), so drive Cursor sessions from macOS or NixOS. The rules behind those switches and the `/harness` commands are in `.agents/instructions/agents-and-skills.instructions.md`.
