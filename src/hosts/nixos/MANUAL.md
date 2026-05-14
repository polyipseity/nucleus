# nixos manual steps

- After first install, run `sudo nixos-generate-config --dir /tmp/nixos-generate-config`, compare the generated hardware values with `src/hosts/nixos/hardware/{cpu,gpu,disks}.nix`, and copy only host-specific hardware facts (filesystem UUIDs, swap, kernel modules, and device paths) into those managed files.
- Rebuild once after updating hardware fragments to confirm there are no missing device references.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.
- For `iCloud`, use your regular Apple ID password (not an app-specific password), complete 2FA, and re-authenticate with `rclone config reconnect iCloud:` when the trust token expires.

## shell aliases

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
- `nr` — run `bun run`.
- `nx` — run `bun x`.
- `v` — open `nvim`.
