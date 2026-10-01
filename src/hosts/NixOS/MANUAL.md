# NixOS manual steps

Steps `nucleus-apply` cannot do. Everything else is already converged.

## first install

1. Partition the disk, `mkfs.btrfs` the root partition, `btrfs subvolume create @` and `btrfs subvolume create @nix`, mount `@` at `/mnt` and `@nix` at `/mnt/nix`, then run `nixos-install`. `src/hosts/NixOS/hardware/disks.nix` declares the layout.
2. `sudo nixos-generate-config --dir /tmp/nixos-generate-config`, then merge the host-specific facts (filesystem UUIDs, EFI `/boot`, swap, kernel modules, device paths) into `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix` and uncomment the `/boot` vfat entry. Rebuild to confirm nothing dangles.

## apps

1. Chrome Remote Desktop Host has no nixpkgs package (nixpkgs #34084, closed as not planned). Install Google's Debian package, add your user to the `chrome-remote-desktop` group, write `~/.chrome-remote-desktop-session`, then finish "Set up remote access" at <https://remotedesktop.google.com/access>. Log in through an X11 session: a Wayland login connects the host to a black screen.
2. WhatsApp has no Linux client; use WhatsApp Web. The `apps.json` entry is intentionally `omitted`.
3. Picard: sign in and add the AcoustID API key under Options.
4. EasyEffects: add a Limiter or Compressor under Effects > Output to cap volume. Presets come from <https://github.com/Digitalone1/EasyEffects-Presets>, cloned into `~/.local/share/easyeffects/output/`.
5. CamillaDSP loopback: `arecord -l | grep Loopback`. Missing after apply means a reboot is needed.

## secrets and remotes

1. Generate `rclone_config_pass`: `openssl rand -hex 64` into `rclone_config_pass` in `src/secrets/users/<username>.yml`, commit, re-run `nucleus-apply`. Delete `~/.config/rclone/rclone.conf` first when unencrypted remotes exist.
2. Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.

## recovery

1. Caddy local-CA trust runs during apply. To redo it: `sudo caddy trust --address 127.0.0.1:2019`.
2. LiteLLM returning HTTP 429/500 (`Missing credentials`, `No deployments available`) on every `default` request means the daemon was built with no `KEYFILE:ENVVAR` pairs, usually because `src/modules/lib/env-secrets.nix` is out of sync with the decrypted SOPS secrets. Check `systemctl cat litellm.service | grep ExecStart`, then run `nucleus-apply` and `nucleus-svc restart litellm`. `ai.nix` fails eval first when the catalog declares keys that resolve to nothing.

## speech to text

1. Transcribe a file: `whisper-cli -m ~/.local/share/nucleus/models/ggml-base.en.bin -f <audio-file>`.
2. Transcribe live: `whisper-stream -m ~/.local/share/nucleus/models/ggml-base.en.bin`. Add `--step 0` for discrete segments instead of a rolling window.
3. `whisper-stream` opens an SDL2 window; close it to stop. PipeWire captures the microphone, so a missing source in `pw-cli list-sources` is a PipeWire problem, not a whisper.cpp one.

## harness bridge

Set `services.hermes-agent.gateway.enable = true` for this host, otherwise nothing can arrive remotely; apply enables the `harness-bridge` plugin and runs the gateway as a user service. To provision a channel once: seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN` in your SOPS file, list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, set `platforms.<name>.enabled` in the gateway config, then re-run `nucleus-apply`. Check the gateway with `systemctl --user status hermes-agent`.

Remote approvals are off by default: `nucleus-config set harness-approval.enable true` to enable them. `nucleus-config get harness-notify.channels` lists the notification channels; `nucleus-config set harness-notify.enable false` stops the bridge on this machine.

The rules behind those switches and the `/harness` commands are in `.agents/instructions/agents-and-skills.instructions.md`.
