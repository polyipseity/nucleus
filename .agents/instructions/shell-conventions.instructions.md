---
description: "Use when editing shell module configuration, zsh alias/function interaction, or shell history exclusion rules."
name: "Shell Conventions"
applyTo: "src/modules/shell*.nix, src/scripts/shell/**"
---

# Shell conventions

## Shell module conventions

**zsh alias-vs-function precedence**: aliases expand before function lookup in zsh. A `shellAliases` entry with the same name as a function silently shadows the function. Never add a `shellAliases` entry matching a function defined in `initContent` or `initExtra`. Canonical example: thefuck — `eval $(thefuck --alias)` defines a function; adding `fuck = "thefuck"` as an alias shadows it.

## Shell history exclusion

All managed shells exclude space-prefixed commands and consecutive duplicates:

| Feature | zsh | PowerShell | cmd.exe |
| --------- | ----- | ----------- | --------- |
| Space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | No equivalent |
| Consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | No equivalent |

Files: zsh `src/scripts/shell/init.zsh`, PowerShell `src/scripts/shell/profile.ps1`. When adding a new shell, enable the equivalent.
