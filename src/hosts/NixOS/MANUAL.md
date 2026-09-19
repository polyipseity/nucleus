# NixOS manual steps

- After first install (Btrfs with `@` root and `@nix` for `/nix` per `src/hosts/NixOS/hardware/disks.nix`): partition the disk, `mkfs.btrfs` on the root partition, `btrfs subvolume create @` and `btrfs subvolume create @nix`, mount `@` at `/mnt` and `@nix` at `/mnt/nix`, then run `nixos-install`. Generate hardware config: `sudo nixos-generate-config --dir /tmp/nixos-generate-config`. Compare with `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix` and merge host-specific facts (filesystem UUIDs, EFI `/boot`, swap, kernel modules, device paths). Uncomment the `/boot` vfat entry in `disks.nix` when merging. Rebuild to confirm no missing references.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open EasyEffects, add Limiter or Compressor under Effects > Output to cap volume. For presets: clone <https://github.com/Digitalone1/EasyEffects-Presets> into `~/.local/share/easyeffects/output/`.
- Verify CamillaDSP loopback: `arecord -l | grep Loopback`. If missing, reboot after `nucleus-apply`.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.

## recurring operations

- Chrome Remote Desktop Host has no nixpkgs package (nixpkgs #34084 was closed as not planned), and Linux has no equivalent approval step. Install Google's Debian package, add your user to the `chrome-remote-desktop` group, write `~/.chrome-remote-desktop-session`, then open <https://remotedesktop.google.com/access> in Chrome and finish "Set up remote access". CRD runs its own virtual X session, so log in to an X11 session; a Wayland login connects the host to a black screen. The `apps.json` entry tracks it as `manual`: activation installs nothing and never force-launches it.
- If `nucleus-svc litellm` is active but every `default` request fails with HTTP 429/500 (`Missing credentials` / `No deployments available`), the daemon was built with no API-key pairs, usually because `src/modules/env-catalog.nix` is out of sync with decrypted SOPS secrets. Confirm with `systemctl cat litellm.service | grep ExecStart`. If there are no `KEYFILE:ENVVAR` pairs, run `nucleus-apply` to rebuild, then `nucleus-svc restart litellm`. The build-time assertion in `ai.nix` fails eval fast if the catalog declares keys but none resolve.
- WhatsApp has no Linux client. Use WhatsApp Web in the browser; the NixOS `apps.json` entry is intentionally `omitted`.
- Harness bridge (desktop reminders, remote approvals, and remote prompts for Cursor, VS Code Copilot Chat, opencode, and pi): it needs the Hermes gateway, which the MacBook enables by default, so set `services.hermes-agent.gateway.enable = true` for this host before anything can arrive remotely; the `harness-bridge` plugin is enabled by `nucleus-apply`. Provision a channel once — seal `TELEGRAM_BOT_TOKEN`, or `NTFY_TOPIC` with `NTFY_TOKEN`, or `DISCORD_BOT_TOKEN`, in your SOPS file — list it in `src/users/<user>/env-secrets.json` with `consumers: ["hermes-agent"]`, turn that platform on in the gateway config (`platforms.<name>.enabled`), and re-run `nucleus-apply`. Check the gateway with `systemctl --user status hermes-agent`. Notifications go to every channel in `nucleus-config get harness-notify.channels`; remove one there to mute it, or run `nucleus-config set harness-notify.enable false` to stop notifications on this machine. Reply `/harness approve <id>` or `/harness deny <id>` to answer a pending tool call, `/harness sessions` to list what is pending, and `/harness send <harness> <text>` to inject a prompt into a waiting session. An unanswered request asks locally instead, after `nucleus-config get harness-approval.timeout-seconds` (default 120 s), so the `timeout` on each hook in `~/.agents/hooks/harness-notify.json` and `~/.cursor/hooks.json` must stay larger. Every decision is appended to `~/.local/share/nucleus/logs/harness-bridge.log`. All four harnesses can be driven remotely here; Cursor ignores remote prompts on Windows only.

## command shortcuts

- `-g`, `-ga`, `-gb`, `-gc`, `-gca`, `-gcl`, `-gco`, `-gd`, `-gf`, `-gff`, `-gl`, `-gp`, `-gpl`, `-gplf`, `-gs`, `-gst`, `-gsw` — git commands
- `-optimize-pdf-default`, `-optimize-pdf-ebook`, `-optimize-pdf-prepress`, `-optimize-pdf-printer`, `-optimize-pdf-screen` — Ghostscript PDF optimization profiles
- `-la`, `-ll` — `eza -la`
- `-n`, `-na`, `-nb`, `-nc`, `-nci`, `-ncl`, `-nf`, `-nff`, `-ni`, `-nl`, `-no`, `-nr`, `-nrm`, `-nt`, `-nu`, `-nup`, `-nw`, `-nx` — bun commands
- `-v` — `nvim`

## nucleus commands

- `nucleus-ai` — manage AI models (sync, list, status, endpoint, config)
- `nucleus-apply` — apply configuration
- `nucleus-bootstrap` — bootstrap system
- `nucleus-update lockfile` — update version pins in `src/lockfiles/lockfile.json`; pass `--sections winget,scoop,...` for specific sections
- `suggestions.*` sections (homebrew.masApps, ollama, vscode, vm-setup.windows) are warn-only and never enforced. `nucleus-update lockfile --verify-installed` always warns for them.
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
- `nucleus-vm setup` — build and provision VMs from `src/modules/vms/VMs.json`. Requires `libvirtd` active (from `vms.nix`). Guest config applies automatically; run `nixos-rebuild switch` inside the guest for manual re-apply.
  - **macOS guest**: not automated (Apple EULA restricts redistribution).
  - **NixOS guest**: built by `nixos-generators`.
  - **Windows 11 guest**: ISO downloaded by Fido; fallback `--windows-iso /path/to/Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>).
  - **Android guest** (LineageOS): libvirt/KVM; ADB at `localhost:22040`. See `.agents/instructions/vm-management.instructions.md` (android-config). Run `nucleus-vm android-config Android` without flags for step-by-step instructions.
- `nucleus-vm resize <id> <size>` — grow-only runtime disk; see `vm-management.instructions.md`
- `nucleus-vm pack` / `nucleus-vm unpack` — cross-host migration; see `vm-management.instructions.md`
