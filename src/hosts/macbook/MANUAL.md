# macbook manual steps

- BetterDisplay: grant Accessibility + Screen Recording in System Settings > Privacy & Security.
- Closed-lid agent work: keep the Mac on AC power when you expect long-running agents or remote sessions to stay alive with the lid shut.
- Closed-lid agent work: Apple documents that closing a Mac laptop display puts it to sleep, and "wake for network access" only wakes a sleeping Mac for sharing traffic; it does not keep existing AI jobs executing. Nucleus mitigates this with BetterDisplay's managed `HeadlessDisplay` virtual display, so if closed-lid work stops, reopen BetterDisplay once and re-run apply.
- Battery: open battery.app once and complete setup so `/usr/local/bin/battery` is installed.
- Chrome Remote Desktop: visit <https://remotedesktop.google.com/access> to name this Mac and set a PIN.
- Chrome Remote Desktop: grant Screen Recording + Accessibility to `ChromeRemoteDesktopHost`.
- Gemini app: intentionally not managed declaratively on macOS because Raycast is the only allowed owner of `Option+Space` on this host.
- Gemini app: if you install `Gemini.app` manually, keep its global shortcut disabled so it never steals `Option+Space` from Raycast.
- LinearMouse: open `LinearMouse.app` once and grant Accessibility permission in System Settings > Privacy & Security > Accessibility.
- Power button: System Settings → General → Shutdown Behavior → set "When I press the power button" to **Sleep** (not Shut Down). This cannot be set via pmset; it is a user preference managed by the OS.

## Shell aliases (full reference)

These aliases are managed declaratively and are available in both zsh and PowerShell profiles.

| Alias                  | Full form                              | Description                                        |
| ---------------------- | -------------------------------------- | -------------------------------------------------- |
| `g`                    | `git`                                  | Run Git directly with full argument passthrough.   |
| `ga`                   | `git add`                              | Stage files/changes.                               |
| `gc`                   | `git commit`                           | Create a commit.                                   |
| `gca`                  | `git commit --amend`                   | Amend the most recent commit.                      |
| `gco`                  | `git checkout`                         | Switch branches or restore paths.                  |
| `gd`                   | `git diff`                             | Show working tree/staged diffs.                    |
| `gll`                  | `git log --oneline --decorate --graph` | Compact decorated commit graph.                    |
| `gp`                   | `git push`                             | Push refs to remote.                               |
| `gpl`                  | `git pull`                             | Pull/fetch and integrate upstream changes.         |
| `gst`                  | `git status`                           | Full Git status output.                            |
| `la`                   | `eza -la`                              | Detailed all-files directory listing.              |
| `ll`                   | `eza -la`                              | Same as `la` for muscle-memory parity.             |
| `ni`                   | `bun install`                          | Install Bun project dependencies.                  |
| `nr`                   | `bun run`                              | Run Bun project scripts.                           |
| `nucleus-gc`           | `nix run ./src#gc`                     | Run repository garbage-collection workflow.        |
| `nucleus-health-check` | `nix run ./src#health-check`           | Run repository health checks.                      |
| `nucleus-update`       | `nix run ./src#update`                 | Run repository update workflow.                    |
| `nx`                   | `bun x`                                | Run one-off Bun package executables (`npx`-style). |
| `v`                    | `nvim`                                 | Open Neovim.                                       |
