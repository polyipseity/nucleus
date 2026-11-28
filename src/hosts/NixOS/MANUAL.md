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
6. The ALSA default routes into the loopback, so audio is silent while `camilladsp` is stopped: start `camilladsp`, or point the app at a `hw:` card. The loopback takes one client at a time and does not mix. The same node serves capture, so a recorder that opens `default` reads the loopback instead: give `arecord` the card (`arecord -D hw:CARD=<card>`) and `whisper-stream` a capture id that is not the default (`whisper-stream --capture <id>`); `arecord -l` lists the cards.
7. Do not set a config's playback device to `default` or to the loopback card: both resolve back into the card the config captures from, so its own output returns as input. The shipped configs leave playback `null` on purpose, which is what lets the heartbeat choose the card.

## system

1. pi reports its sandbox state through the `sandbox` status indicator: `SANDBOX: srt` inside the srt sandbox and `SANDBOX: NONE (unsandboxed)` outside it. Run `/sandbox-status` for the evidence, mode, resolved `rm`, `safe-rm`/`rip` presence, and the `safe-delete` filter's `unproven` setting. The unsandboxed warning is emitted once per process.

## secrets and remotes

1. Generate `rclone_config_pass`: `openssl rand -hex 64` into `rclone_config_pass` in `src/secrets/users/<username>.yml`, commit, re-run `nucleus-apply`. Delete `~/.config/rclone/rclone.conf` first when unencrypted remotes exist.
2. Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.

## recovery

1. Caddy local-CA trust runs during apply. To redo it: `sudo caddy trust --address 127.0.0.1:2019`.
2. LiteLLM returning HTTP 429/500 (`Missing credentials`, `No deployments available`) on every `default` request means the daemon was built with no `KEYFILE:ENVVAR` pairs, usually because `src/modules/lib/env-secrets.nix` is out of sync with the decrypted SOPS secrets. Check `systemctl cat litellm.service | grep ExecStart`, then run `nucleus-apply` and `nucleus-svc restart litellm`. `ai.nix` fails eval first when the catalog declares keys that resolve to nothing.

## speech to text

1. Transcribe a file: `whisper-cli -m ~/.local/share/nucleus/models/ggml-base.en.bin -f <audio-file>`.
2. Transcribe live: `whisper-stream -m ~/.local/share/nucleus/models/ggml-base.en.bin`. Add `--step 0` for discrete segments instead of a rolling window.
3. `whisper-stream` opens an SDL2 window; close it to stop. It opens a capture device of its own through ALSA, since this host runs no PipeWire, so a missing or wrong source is an ALSA device question: `arecord -l` lists what is available.
4. Clean a recording: `deep-filter -m ~/.local/share/nucleus/models/DeepFilterNet3_onnx.tar.gz -o out.wav in.wav`.

## harness bridge

Set `services.hermes-agent.gateway.enable = true` for this host, otherwise nothing can arrive remotely; apply enables the `harness-bridge` plugin and runs the gateway as a user service. To provision a channel once: seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN` in your SOPS file, list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, set `platforms.<name>.enabled` in the gateway config, then re-run `nucleus-apply`. Check the gateway with `systemctl --user status hermes-agent`.

Approval sources default to `["prompt","hermes"]`. Hermes waits 300 seconds and the terminal prompt waits 600 seconds as independent races, so the first answer wins. An all-timeout decision is a typed deny with source `all-timeouts` and reason `all approval sources timed out (hermes 300s, prompt 600s)`. `nucleus-config get harness-notify.channels` lists the notification channels; `nucleus-config set harness-notify.enable false` stops the bridge on this machine. The six-field decision contract and native rendering live in `.agents/instructions/harness-adapters.reference.md`.

Proof the local Hermes profile with `hermes model`, `hermes chat -q "Reply with exactly: ready"` for a real model call, and `hermes chat -q "Use the shell tool to print the current working directory" -v` for a real tool call. Keep the terminal output.

Proof the gateway with `systemctl --user status hermes-agent` and `hermes --profile gateway gateway status`. Send one real Telegram message and one real Discord message from approved accounts, and publish one message to the private ntfy topic. Keep the replies in Telegram and Discord and the delivered ntfy message. Pair unknown senders with `hermes --profile gateway pairing list`, `hermes --profile gateway pairing approve telegram <request-id or code>`, `hermes --profile gateway pairing approve discord <request-id or code>`, then `hermes --profile gateway pairing list` again for pairing state.

Proof a harness approval: trigger a tool call that reaches the gate, run `/harness status` in a Hermes session, answer with `/harness approve <id>` or `/harness deny <id>`, keep the decision output, and read the event with `nucleus-logs show harness --json`.

If apply fails on `/nix`, collect evidence before choosing a fix: `bash src/scripts/diagnostics/collect-apply-failure.sh <output-file>`. Keep the written decision on the store-lock holder. Nothing reclaims the store automatically.

The rules behind those switches and the `/harness` commands are in `.agents/instructions/agents-and-skills.instructions.md`.
