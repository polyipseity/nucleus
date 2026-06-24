# windows manual steps

- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `%USERPROFILE%\.config\rclone\rclone.conf` first so the remotes are re-created with encryption.
- Run `nucleus-cloud-setup` in PowerShell and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.
- Open MusicBrainz Picard, then sign in with your MusicBrainz account in `Options > General`.
- In MusicBrainz Picard, add your AcoustID user API key in `Options > Fingerprinting`, then save.
- Run the **Equalizer APO** configurator once to select your playback device, then reboot.
- Launch **Peace Equalizer APO** (Peace GUI). Click the Effects button and use the visual Limiter sliders or pre-amplification dial to cap the system output threshold.
- Run `camilladsp --list-devices` to list WASAPI device names. If the default device name in `src/modules/configs/camilladsp/configs/windows/config.yml` does not match your output device, update it.



## HTTPS certificate trust (one-time)

- `nucleus-apply` now runs Caddy local-CA trust automatically for managed localhost HTTPS reverse proxies.
- If trust is still missing after apply, run `caddy trust --address 127.0.0.1:2019` once in an elevated PowerShell session.

## NTFS filesystem support

- Native NTFS read/write is built into the Windows kernel. No drivers, services, or configuration needed — external NTFS drives work plug-and-play.

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
- `nucleus-bootstrap` — run the managed bootstrap flow.
- `nucleus-bump-lockfile` — update all version pins in the consolidated lockfile (`src/lockfiles/lockfile.json`) from upstream sources; pass `-Sections winget,scoop,...` to update specific sections.
- `nucleus-check-pwsh` — run PowerShell syntax checks.
- `nucleus-check-sh` — run POSIX shell syntax checks.
- `nucleus-cloud-setup` — configure required cloud remotes and re-run apply.
- `nucleus-gc` — run the managed Nix garbage-collection flow.
- `nucleus-health-check` — run the managed repository health checks.
- `nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nucleus-vm-setup` — build (if needed) and provision QEMU VMs declared in `src/modules/VMs.json`; run once per machine. NixOS guest uses Packer (ISO auto-downloaded). Windows 11 guest auto-resolves the installer when possible and falls back to `-WindowsIso C:\path\to\Win11.iso` (download from <https://www.microsoft.com/software-download/windows11>) when auto-resolution fails; use `-Accelerator whpx` if Windows HyperVisor Platform is enabled. Requires QEMU (managed by Scoop). Run `start-<name>.ps1` in `%USERPROFILE%\virtual machines\`. Guest converge is automatic during provisioning; run `.\src\hosts\Windows\apply.ps1` inside the guest for manual re-converge.
