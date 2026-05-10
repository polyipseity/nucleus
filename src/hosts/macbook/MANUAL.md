# macbook manual steps

- BetterDisplay: grant Accessibility + Screen Recording in System Settings > Privacy & Security.
- Battery: open battery.app once and complete setup so `/usr/local/bin/battery` is installed.
- Chrome Remote Desktop: visit <https://remotedesktop.google.com/access> to name this Mac and set a PIN.
- Chrome Remote Desktop: grant Screen Recording + Accessibility to `ChromeRemoteDesktopHost`.
- LinearMouse: open `LinearMouse.app` once and grant Accessibility permission in System Settings > Privacy & Security > Accessibility.
- Power button: System Settings → General → Shutdown Behavior → set "When I press the power button" to **Sleep** (not Shut Down). This cannot be set via pmset; it is a user preference managed by the OS.

## Shell aliases (full reference)

These aliases are managed declaratively and are available in both zsh and PowerShell profiles.

| Alias | Full form | Description |
| --- | --- | --- |
| `g` | `git` | Run Git directly with full argument passthrough. |
| `ga` | `git add` | Stage files/changes. |
| `gc` | `git commit` | Create a commit. |
| `gca` | `git commit --amend` | Amend the most recent commit. |
| `gco` | `git checkout` | Switch branches or restore paths. |
| `gd` | `git diff` | Show working tree/staged diffs. |
| `gl` | `git log --oneline --decorate --graph` | Compact decorated commit graph. |
| `gp` | `git push` | Push refs to remote. |
| `gpl` | `git pull` | Pull/fetch and integrate upstream changes. |
| `gs` | `git status -sb` | Short branch-aware Git status. |
| `gst` | `git status` | Full Git status output. |
| `la` | `eza -la` | Detailed all-files directory listing. |
| `ll` | `eza -la` | Same as `la` for muscle-memory parity. |
| `ni` | `bun install` | Install Bun project dependencies. |
| `nr` | `bun run` | Run Bun project scripts. |
| `nucleus-gc` | `nix run ./src#gc` | Run repository garbage-collection workflow. |
| `nucleus-health-check` | `nix run ./src#health-check` | Run repository health checks. |
| `nucleus-update` | `nix run ./src#update` | Run repository update workflow. |
| `nx` | `bun x` | Run one-off Bun package executables (`npx`-style). |
| `v` | `nvim` | Open Neovim. |
