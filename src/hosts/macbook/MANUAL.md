# macbook manual steps

## One-Time Configuration

- Configure Raycast database-only settings: see [raycast-manual-config.md](raycast-manual-config.md) for step-by-step guide. This includes the main hotkey (⌘Space), Clipboard History hotkey (⌥⌘C), search sensitivity, vim keybindings, and other advanced options that cannot be declaratively managed.
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

- `nucleus-AI-sync` — run the managed AI model sync flow.
- `nucleus-apply` — run the managed apply flow.
- `nucleus-cloud-setup` — configure required cloud remotes and re-run apply.
- `nucleus-gc` — run the managed Nix garbage-collection flow.
- `nucleus-health-check` — run the managed repository health checks.
- `nucleus-replica-sync` — run one-shot pull sync for enabled cloud replicas.
- `nucleus-replica-reset` — clear local replica state without touching remote data.
- `nucleus-update` — run the managed repository update flow.
- `nucleus-VM-setup` — provision UTM virtual machines declared in `src/modules/VMs.json`. Run once after `nucleus apply` on a new machine or to add a new VM. Requires UTM to have been launched at least once (to initialise its sandboxed document store). After provisioning, open UTM, locate each VM, and attach an installation ISO to install the guest OS. Verify the generated config.plist values in UTM's settings GUI before first boot.
