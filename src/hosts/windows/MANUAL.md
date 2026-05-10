# windows manual steps

## Gemini CLI first-run initialization

1. Run `gemini` in any terminal.
2. Select **Sign in with Google**.
3. Verify with `gemini --version` (expected: `0.38` or newer).

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
| `gl`                   | `git log --oneline --decorate --graph` | Compact decorated commit graph.                    |
| `gp`                   | `git push`                             | Push refs to remote.                               |
| `gpl`                  | `git pull`                             | Pull/fetch and integrate upstream changes.         |
| `gs`                   | `git status -sb`                       | Short branch-aware Git status.                     |
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
