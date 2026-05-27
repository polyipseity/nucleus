# nixos manual steps

- After first install, run `sudo nixos-generate-config --dir /tmp/nixos-generate-config`, compare the generated hardware values with `src/hosts/NixOS/hardware/{cpu,gpu,disks}.nix`, and copy only host-specific hardware facts (filesystem UUIDs, swap, kernel modules, and device paths) into those managed files.
- Rebuild once after updating hardware fragments to confirm there are no missing device references.
- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `~/.config/rclone/rclone.conf` first so the remotes are re-created with encryption.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.

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
- `nucleus-vm-setup` — build (if needed) and provision KVM/libvirt VMs declared in `src/modules/VMs.json`; run once per machine or when adding a VM. Requires `libvirtd` active (from `vms.nix`). Run `~/virtual machines/<name>-configure.sh` on the host to print the exact command to run inside the guest.
  - **macOS guest**: macOS VM build is not automated on NixOS (Apple EULA restricts redistribution). The entry exists in `VMs.json` but `nucleus-vm-setup` skips the image build step.
  - **NixOS guest** (`--nixos-only`): fully automatic; `nixos-generators` builds the image (no extra tools needed).
  - **Windows 11 guest** (`--windows-only`): attempts to auto-download the ISO from Microsoft on first run (Fido-style); falls back to `--windows-iso /path/to/Win11.iso` if auto-fetch fails (download from <https://www.microsoft.com/software-download/windows11>).
