---
description: "Use always: safe file deletion policy covering all platforms and agents. Never use rm/del/rd/erase/Remove-Item/cmd directly; use recoverable alternatives."
name: "File Deletion Safety"
applyTo: "**"
alwaysApply: true
---

# File Deletion Safety

## Rules
- Never use `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, or `Remove-Item` directly.
- **POSIX**: use `shell-safe-rm` (moves to OS Trash, recoverable) or `rip`/`rip2` (moves to graveyard, recoverable; undo with `rip -u`).
- **Windows PowerShell**: the built-in `rm`/`del`/`rd`/`erase`/`ri`/`Remove-Item` aliases are safe (recycle to Recycle Bin).
- **Windows cmd/Git Bash**: use `rip` (available on PATH).
- Motivation: direct deletion is not recoverable. Safe alternatives are recoverable.

## Agent constraints
- On Windows, never invoke `cmd.exe` or `cmd`; always use `pwsh`.
- On non-Windows, never invoke `/bin/rm` directly (bypasses protection).
