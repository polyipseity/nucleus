# macbook manual steps

## One-Time Configuration

- Open `fuse-t.app` once, then enable the `fuse-t` File System Extension in `System Settings > General > Login Items & Extensions > Extensions`.
- Run `nucleus-cloud-setup` and complete `rclone config` for `GoogleDrive`, `iCloud`, and `OneDrive` when prompted.
- Finder sidebar favorites set by `nucleus apply` are visible only after restarting macOS (log out and back in, or reboot).

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
- `nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nr` — run `bun run`.
- `nx` — run `bun x`.
- `v` — open `nvim`.
