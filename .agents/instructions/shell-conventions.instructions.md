---
description: "Use when editing shell module configuration, zsh alias/function interaction, srt sandbox wrappers, or shell history exclusion rules."
name: "Shell Conventions"
applyTo: "src/modules/shell/**, src/scripts/shell/**"
---

# Shell conventions

## zsh aliases and functions

zsh expands an alias before it looks up a function, so a `shellAliases` entry silently shadows a function of the same name. Never add a `shellAliases` entry matching a function defined in `initContent` or `initExtra`: `eval $(thefuck --alias)` defines the function, so an alias `fuck = "thefuck"` would break it.

## Sandbox wrappers

srt parses its own options anywhere on the line, including after the wrapped command, so every srt-wrapped command needs `--` between the command and the forwarded arguments: `srt command pi -- "$@"`. Without it `pi --help` prints srt's help and `pi -c <arg>` drops the argument silently. `srt -c '<string>'` needs no separator, since the string is a single argument. Check step 11 (`run_srt_wrapper_invariants`) rejects a wrapper that omits it.

`pi-unrestricted` must resolve the application from PATH explicitly. In zsh `command pi "$@"` bypasses the function; in PowerShell `& pi` calls the wrapper and stays sandboxed, so use `Get-Command <name> -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1` (every PATH entry carries its own copy under Nix, so the array needs narrowing) and throw when nothing resolves.

## History exclusion

| Feature | zsh | PowerShell | cmd.exe |
| --------- | ----- | ----------- | --------- |
| Space-prefixed commands | `setopt HIST_IGNORE_SPACE` | `-AddToHistoryHandler { ... }` | No equivalent |
| Consecutive duplicates | `setopt HIST_IGNORE_DUPS` | `-HistoryNoDuplicates` | No equivalent |

zsh lives in `src/scripts/shell/init.zsh`, PowerShell in `src/scripts/shell/profile.ps1`; a new managed shell enables the equivalent.
