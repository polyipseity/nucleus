# windows manual steps

- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `%USERPROFILE%\.config\rclone\rclone.conf` first so the remotes are re-created with encryption.
- Run `nucleus-cloud-setup` in PowerShell and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.

## accessible ports

- `https://localhost:8920` — Jellyfin HTTPS endpoint (Caddy local reverse proxy).
- `http://127.0.0.1:8096` — Jellyfin internal loopback HTTP API (automation upstream).
- `http://127.0.0.1:11434` — Ollama local API.
- `tcp/5985` — WinRM HTTP listener.
- `tcp/3389` — Windows Remote Desktop.

## HTTPS certificate trust (one-time)

- Trust the local Caddy CA so `https://localhost:8920` is recognized by browsers: run `caddy trust --address 127.0.0.1:2019` in an elevated PowerShell session.

## command shortcuts

- `-g` — run `git`.
- `-ga` — run `git add`.
- `-gb` — run `git branch`.
- `-gc` — run `git commit`.
- `-gca` — run `git commit --amend`.
- `-gcl` — run `git clone`.
- `-gco` — run `git checkout`.
- `-gd` — run `git diff`.
- `-gf` — run `git fetch`.
- `-gl` — run `git log --oneline --decorate --graph`.
- `-gst` — run `git status`.
- `-gp` — run `git push`.
- `-gpl` — run `git pull`.
- `-gs` — run `git status -sb`.
- `-gs-pdf-opt-default` — optimize PDFs with Ghostscript default profile.
- `-gs-pdf-opt-ebook` — optimize PDFs with Ghostscript ebook profile.
- `-gs-pdf-opt-prepress` — optimize PDFs with Ghostscript prepress profile.
- `-gs-pdf-opt-printer` — optimize PDFs with Ghostscript printer profile.
- `-gs-pdf-opt-screen` — optimize PDFs with Ghostscript screen profile.
- `-gsw` — run `git switch`.
- `-la` — run `eza -la`.
- `-ll` — run `eza -la`.
- `-ni` — run `bun install`.
- `-nr` — run `bun run`.
- `-nx` — run `bun x`.
- `-v` — open `nvim`.

## nucleus commands

- `nucleus-ai-sync` — run the managed AI model sync flow.
- `nucleus-apply` — run the managed apply flow.
- `nucleus-cloud-setup` — configure required cloud remotes and re-run apply.
- `nucleus-gc` — run the managed Nix garbage-collection flow.
- `nucleus-health-check` — run the managed repository health checks.
- `nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nucleus-vm-setup` — build (if needed) and provision QEMU VMs declared in `src/modules/VMs.json`; run once per machine. NixOS guest uses Packer (ISO auto-downloaded). Windows 11 guest auto-resolves the installer when possible and falls back to `-WindowsIso C:\path\to\Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>) when auto-resolution fails; use `-Accelerator whpx` if Windows HyperVisor Platform is enabled. Requires QEMU (managed by Scoop). Run `Start-<Name>.ps1` in `%USERPROFILE%\virtual machines\`. Run `<name>-configure.ps1` to print the guest configuration command.
