# macbook manual steps

## One-Time Configuration

- **Raycast clipboard history hotkey**: Open Raycast Settings (⌘,) → Shortcuts tab → Search "Clipboard History" → Click the Record Hotkey field → Press ⌥⌘C (Option+Command+C). Hotkey is stored in Raycast's database and persists across updates.
- Configure Raycast database-only settings: see [raycast-manual-config.md](raycast-manual-config.md) for step-by-step guide. This includes setting the main hotkey to cmd+space, search sensitivity to high, vim keybindings, and other advanced options that cannot be declaratively managed.
- **Menu bar icons**: AltTab, BetterDisplay, and LinearMouse are hidden automatically. To hide `MiddleClick`, hold `⌘`, drag its menu bar icon away until `✖️` appears, then release. Re-open MiddleClick while it is already running to show the icon again.
- Grant Accessibility to BetterDisplay, Chrome Remote Desktop Host, and MiddleClick (MiddleClick requires this to synthesize mouse button events).
- Grant Screen Recording to BetterDisplay and Chrome Remote Desktop Host.
- Open `fuse-t.app` once, then enable the `fuse-t` File System Extension in `System Settings > General > Login Items & Extensions > Extensions`.
- Open `battery.app` once so `/usr/local/bin/battery` is installed.
- Sign in to the App Store once so `mas` installs can provision Xcode.
- Create the per-user rclone passphrase: from the repo root, run `sops edit src/secrets/users-<username>.yml`, add `rclone_config_pass: <output of openssl rand -hex 64>`, save (sops encrypts automatically), commit the file, then re-run `nucleus apply`. If you already configured rclone remotes without this passphrase, delete `~/.config/rclone/rclone.conf` first so the remotes are re-created with encryption.
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
