---
description: "Use when editing shell module configuration, zsh alias and function interaction, srt sandbox wrappers, or shell history rules."
name: "Shell Conventions"
applyTo: "src/modules/shell/**, src/scripts/shell/**"
---

# Shell conventions

## zsh aliases and functions

zsh expands an alias before looking up a function, so a `shellAliases` entry silently shadows a function of the same name. Never add an alias matching a function in `initContent` or `initExtra`. For example, `eval $(thefuck --alias)` defines `fuck`, so an alias `fuck = "thefuck"` breaks it.

## Sandbox wrappers

srt parses its options anywhere on the line, including after the wrapped command. Every srt-wrapped command needs `--` before forwarded arguments: `srt command pi -- "$@"`. Without it `pi --help` shows srt help and `pi -c <arg>` drops the argument. `srt -c '<string>'` needs no separator.

`pi-unrestricted` resolves the application from PATH explicitly. In zsh, `command pi "$@"` bypasses the function. In PowerShell, `& pi` calls the wrapper and stays sandboxed, so use `Get-Command <name> -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1` and throw when nothing resolves. Nix puts a copy in every PATH entry, hence the narrowing.

## History exclusion

| Feature | zsh | PowerShell | cmd.exe |
| --- | --- | --- | --- |
| Space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | none |
| Consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | none |

zsh lives in `src/scripts/shell/init.zsh`, PowerShell in `src/scripts/shell/profile.ps1`. A new managed shell enables the equivalent.
