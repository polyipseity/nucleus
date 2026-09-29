---
description: "Use when editing shell module configuration, zsh alias/function interaction, srt sandbox wrappers, or shell history exclusion rules."
name: "Shell Conventions"
applyTo: "src/modules/shell/**, src/scripts/shell/**"
---

# Shell conventions

## Shell module conventions

**zsh alias-vs-function precedence**: aliases expand before function lookup in zsh. A `shellAliases` entry with the same name as a function silently shadows the function. Never add a `shellAliases` entry matching a function defined in `initContent` or `initExtra`. Canonical example: thefuck — `eval $(thefuck --alias)` defines a function; adding `fuck = "thefuck"` as an alias shadows it.

## Sandbox wrappers

srt (`@anthropic-ai/sandbox-runtime`) parses its own options wherever they appear on the line, including after the command it wraps. Every srt-wrapped command therefore needs `--` between the wrapped command and the forwarded arguments: `srt command pi -- "$@"`. Without it `pi --help` prints srt's help, and `pi -c <arg>` loses the argument with no error at all. `srt -c '<string>'` is the one form that needs no separator, since the string is a single argument. Check step 11 rejects a wrapper that omits it.

An unrestricted counterpart (`pi-unrestricted`) has to resolve the application from PATH explicitly. In zsh `command pi "$@"` bypasses the function; in PowerShell `& pi` calls the wrapper defined above and stays sandboxed, so use `Get-Command <name> -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1` (every PATH entry carries its own copy under Nix, so the array must be narrowed) and throw when nothing resolves.

## Shell history exclusion

All managed shells exclude space-prefixed commands and consecutive duplicates:

| Feature | zsh | PowerShell | cmd.exe |
| --------- | ----- | ----------- | --------- |
| Space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | No equivalent |
| Consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | No equivalent |

Files: zsh `src/scripts/shell/init.zsh`, PowerShell `src/scripts/shell/profile.ps1`. When adding a new shell, enable the equivalent.
