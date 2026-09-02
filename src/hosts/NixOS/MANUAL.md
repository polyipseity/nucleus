# NixOS manual steps

- After first install (Btrfs with `@` root and `@nix` for `/nix` per `src/hosts/NixOS/hardware/disks.nix`): partition the disk, `mkfs.btrfs` on the root partition, `btrfs subvolume create @` and `btrfs subvolume create @nix`, mount `@` at `/mnt` and `@nix` at `/mnt/nix`, then run `nixos-install`. Generate hardware config: `sudo nixos-generate-config --dir /tmp/nixos-generate-config`. Compare with `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix` and merge host-specific facts (filesystem UUIDs, EFI `/boot`, swap, kernel modules, device paths). Uncomment the `/boot` vfat entry in `disks.nix` when merging. Rebuild to confirm no missing references.
- Generate `rclone_config_pass` in `src/secrets/users-<username>.yml` via `openssl rand -hex 64`, commit, re-run `nucleus-apply`. If remotes exist without encryption, delete `~/.config/rclone/rclone.conf` first.
- Run `nucleus-cloud setup` and complete `rclone config` for GoogleDrive, iCloud, and OneDrive.
- Open MusicBrainz Picard, sign in, and add AcoustID API key under Options.
- Open EasyEffects, add Limiter or Compressor under Effects > Output to cap volume. For presets: clone <https://github.com/Digitalone1/EasyEffects-Presets> into `~/.local/share/easyeffects/output/`.
- Verify CamillaDSP loopback: `arecord -l | grep Loopback`. If missing, reboot after `nucleus-apply`.
- Caddy local-CA trust runs automatically. If missing: `sudo caddy trust --address 127.0.0.1:2019`.

## recurring operations

- **Chrome Remote Desktop Host**: not packaged in nixpkgs. To enable inbound CRD access, install the host component manually (Google-provided package) and approve the system extension once in System Settings → Privacy & Security. The `apps.json` entry tracks it as a `system-extension` (manual approval); it is not force-launched by activation.
- **LiteLLM recovery**: if `nucleus-svc litellm` is active but every `default` request fails with HTTP 429/500 (`Missing credentials` / `No deployments available`), the daemon was built with no API-key pairs — typically because `src/modules/env-catalog.nix` is out of sync with decrypted SOPS secrets. Confirm with `systemctl cat litellm.service | grep ExecStart` — if no `KEYFILE:ENVVAR` pairs, run `nucleus-apply` to rebuild, then `nucleus-svc restart litellm`. The build-time assertion in `ai.nix` fails eval fast if the catalog declares keys but none resolve.
- **WhatsApp**: no Linux client exists. Use WhatsApp Web in the browser; the NixOS `apps.json` entry is intentionally `omitted`.

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
- `suggestions.*` sections (homebrew.masApps, ollama, vscode, vm-setup.windows) are warn-only — never enforced. `nucleus-update lockfile --verify-installed` always warns for them.
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
- `nucleus-vm setup` — build and provision VMs from `src/modules/VMs.json`. Requires `libvirtd` active (from `vms.nix`). Guest config applies automatically; run `nixos-rebuild switch` inside the guest for manual re-apply.
  - **macOS guest**: not automated (Apple EULA restricts redistribution).
  - **NixOS guest**: built by `nixos-generators`.
  - **Windows 11 guest**: ISO downloaded by Fido; fallback `--windows-iso /path/to/Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>).
  - **Android guest** (LineageOS): libvirt/KVM; ADB at `localhost:22040`. See `.agents/instructions/vm-management.instructions.md` (android-config). Run `nucleus-vm android-config Android` without flags for step-by-step instructions.
- `nucleus-vm resize <id> <size>` — grow-only runtime disk; see `vm-management.instructions.md`
- `nucleus-vm pack` / `nucleus-vm unpack` — cross-host migration; see `vm-management.instructions.md`
