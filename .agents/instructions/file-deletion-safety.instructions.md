---
description: "Use when provisioning or modifying rm-safety on any host. Documents the two-tier POSIX defense, Windows mechanisms, and agent blocking policy."
name: "File Deletion Safety Provisioning Policy"
applyTo: "src/modules/core.nix, src/modules/shell/**, src/scripts/shell/**, src/scripts/safe-delete-*, src/platforms/Windows/**/Sync-SafeDelete.ps1, src/hosts/Windows/**, src/users/default/agents/**"
---

# File Deletion Safety Provisioning Policy

## POSIX (macOS + NixOS)
- **Packages**: `rip2` via managedPackages (nixpkgs + Homebrew). `safe-rm` via bun global (`safe-rm` npm package).
- **Interactive shells**: `rm()` blocks and prints guidance.
- **Non-interactive shells**: `rm()` in `.zshenv` execs `safe-rm`; PATH binary `~/.local/bin/rm` (wrapper) also execs `safe-rm`. Two defenses.
- **Alternatives**: `shell-safe-rm` (OS Trash) or `rip`/`rip2` (graveyard, `rip -u` undo).

## Windows
- **Packages**: `rip2` via custom Scoop manifest. `chrisant996.Clink` via WinGet DSC.
- **PowerShell**: `.NET` recycling via `Invoke-SafeDelete`, aliases `rm`/`del`/`rd`/`erase`/`ri`/`Remove-Item` overridden.
- **cmd.exe**: Clink Lua filter (`%LOCALAPPDATA%\clink\safedel.lua`) + doskey AutoRun fallback. Routes to `rip.exe`.
- **Git Bash**: alias `rm` to `rip`.
- **PATH shims**: `rm.exe`/`del.exe`/`rd.exe`/`rmdir.exe`/`erase.exe`/`ri.exe` copies of `rip.exe` in `%USERPROFILE%\.local\bin`.

## Agent policy
- Instructions: `src/users/default/agents/instructions/file-deletion-safety.instructions.md` (alwaysApply).
- Blocking: PreToolUse/beforeShellExecution hooks deny `rm`, `/bin/rm`, `cmd`/`cmd.exe`.
- Use `pwsh` on Windows; never call `/bin/rm` on POSIX.
