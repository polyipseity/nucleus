---
description: "Use when editing shell module configuration, zsh alias and function interaction, srt sandbox wrappers, or shell history rules."
name: "Shell Conventions"
applyTo: "src/modules/shell/**, src/scripts/shell/**"
---

# Shell conventions

zsh expands aliases before functions, so a `shellAliases` entry must never shadow a function from `initContent` or `initExtra` (`eval $(thefuck --alias)` defines `fuck`). srt parses its options anywhere, so wrapped commands need `--` before forwarded args (`srt command pi -- "$@"`); `srt -c '<string>'` needs none.

`pi-unrestricted` resolves the application explicitly: zsh `command pi "$@"`, PowerShell `Get-Command <name> -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1` and throw when empty. History rules: zsh `HIST_IGNORE_SPACE` / `HIST_IGNORE_DUPS`, PowerShell `-AddToHistoryHandler` / `-HistoryNoDuplicates`, cmd.exe none. New managed shells enable the equivalent.

Details: `.agents/skills/nucleus-platform-reference/references/shell-conventions.md`.
