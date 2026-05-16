# nixos manual steps

- After first install, run `sudo nixos-generate-config --dir /tmp/nixos-generate-config`, compare the generated hardware values with `src/hosts/nixos/hardware/{cpu,gpu,disks}.nix`, and copy only host-specific hardware facts (filesystem UUIDs, swap, kernel modules, and device paths) into those managed files.
- Rebuild once after updating hardware fragments to confirm there are no missing device references.
- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `~/.config/rclone/rclone.conf` first so the remotes are re-created with encryption.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.

## command shortcuts

- `g` — run `git`.
- `ga` — run `git add`.
- `gc` — run `git commit`.
- `gca` — run `git commit --amend`.
- `gco` — run `git checkout`.
- `gd` — run `git diff`.
- `gll` — run `git log --oneline --decorate --graph`.
- `gst` — run `git status`.
- `gp` — run `git push`.
- `gpl` — run `git pull`.
- `gs-pdf-opt-default` — optimize PDFs with Ghostscript default profile.
- `gs-pdf-opt-ebook` — optimize PDFs with Ghostscript ebook profile.
- `gs-pdf-opt-prepress` — optimize PDFs with Ghostscript prepress profile.
- `gs-pdf-opt-printer` — optimize PDFs with Ghostscript printer profile.
- `gs-pdf-opt-screen` — optimize PDFs with Ghostscript screen profile.
- `la` — run `eza -la`.
- `ll` — run `eza -la`.
- `ni` — run `bun install`.
- `nucleus-cloud-setup` — configure required cloud remotes and re-run apply.
- `nucleus-gc` — run the managed Nix garbage-collection flow.
- `nucleus-health-check` — run the managed repository health checks.
- `nucleus-replica-bisync` — run one-shot sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nr` — run `bun run`.
- `nx` — run `bun x`.
- `v` — open `nvim`.
