---
description: "Use when editing shell history exclusion features across managed shells (zsh, PowerShell, cmd.exe). Lists enabled features, file locations, and per-shell equivalents."
name: "Shell History Exclusion"
applyTo: "src/modules/shell.nix, src/modules/pwsh.nix, src/scripts/shell/init.zsh, src/scripts/shell/profile.ps1, src/platforms/Windows/modules/user/Sync-ShellProfile.ps1, src/hosts/Windows/user/shell.dsc.yml"
---

# Shell History Exclusion

## Enabled features

All managed shells exclude two history features:

| Feature | zsh | PowerShell (POSIX) | PowerShell (Windows) | cmd.exe |
| --------- | ----- | --------------------- | ----------------------- | --------- |
| Ignore space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | Same | No equivalent |
| Ignore consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | Same | No equivalent |

## File locations

- **zsh**: `src/scripts/shell/init.zsh`, embedded by `src/modules/shell.nix` (`initContent`)
- **PowerShell (POSIX)**: `src/scripts/shell/profile.ps1` (PSReadLine block), embedded by `src/modules/pwsh.nix` at Nix eval time
- **PowerShell (Windows)**: same `src/scripts/shell/profile.ps1` (PSReadLine block), read back into the managed block by `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` at runtime
- **cmd.exe**: documented limitation in `src/hosts/Windows/user/shell.dsc.yml`

## Adding a new shell

When adding a new shell (bash, fish, nushell, etc.), enable the equivalent:

- **bash**: `HISTCONTROL=ignorespace:ignoredups`
- **fish**: use `fish_history` or custom function
- **nushell**: `$env.config.shell_integration.history.exclude_patterns`
- **cmd.exe**: no equivalent exists
