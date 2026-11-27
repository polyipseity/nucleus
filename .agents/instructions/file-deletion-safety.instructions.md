---
description: "Use when provisioning or modifying file deletion safety on any host."
name: "File Deletion Safety Provisioning"
applyTo: "src/**, scripts/**, tests/**"
alwaysApply: false
---

# File deletion safety provisioning

POSIX: `rip2` via managedPackages and `safe-rm` via bun; zsh interactive blocks for `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, `unlink`, `shred`, and a PATH `rm` wrapper for non-interactive shells. Windows: `rip2` via Scoop, `clink` via WinGet DSC, `Invoke-SafeDelete` overriding the union including `Remove-Item` with .NET recycling, plus clink, doskey, and PATH shims.

`<USER root>\state\safe-delete\shims.json` records `version`, `ripHash`, and every shim path; the guard proves a bare word only when the resolved shim matches the manifest, otherwise `settings.unproven` decides (`ask` default). Native paths, `cmd` in command position, and `find -delete` are denied. `rip` is a no-match allow; heredoc bodies are data, `find -exec` is a command, and `-NoProfile`/`-nop` leaves a word unproven.

`RIP_GRAVEYARD` points to `<USER root>/state/rip/graveyard` on every host and is created by activation; `nucleus-gc graveyard` reports but never deletes. Hook-bearing harnesses run the same filter through `harness decide-call`; Pi and opencode use instructions. Details: `.agents/skills/nucleus-policy-reference/references/file-deletion-safety.md`.
