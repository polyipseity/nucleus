---
description: "Use when editing shell history exclusion features across managed shells (zsh, PowerShell, cmd.exe). Lists enabled features, file locations, and per-shell equivalents."
name: "Shell History Exclusion"
applyTo: "src/modules/shell.nix, src/modules/pwsh.nix, src/hosts/Windows/modules/user/Sync-ShellProfile.ps1, src/hosts/Windows/user/shell.dsc.yml"
---

# Shell History Exclusion Features

## Enabled features

All managed shells now exclude two types of history entries:

| Feature | zsh | PowerShell (POSIX) | PowerShell (Windows) | cmd.exe |
|---------|-----|---------------------|-----------------------|---------|
| Ignore space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | Same | ❌ No equivalent |
| Ignore consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | Same | ❌ No equivalent |

## File locations

- **zsh**: `src/modules/shell.nix` → `initContent`
- **PowerShell (POSIX)**: `src/modules/pwsh.nix` → `profileContent` → PSReadLine block
- **PowerShell (Windows)**: `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` → `$managedBlock` → PSReadLine block
- **cmd.exe**: documented limitation in `src/hosts/Windows/user/shell.dsc.yml`

## Adding a new shell

When adding a new shell (bash, fish, nushell, etc.), enable the equivalent:
- **bash**: `HISTCONTROL=ignorespace:ignoredups`
- **fish**: use `fish_history` or custom function
- **nushell**: `$env.config.shell_integration.history.exclude_patterns`
- **cmd.exe**: no equivalent exists
