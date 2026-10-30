---
description: "Use always: file deletion safety rules. Never use rm or its equivalents directly; use recoverable alternatives. Covers POSIX and Windows."
name: "File Deletion Safety"
applyTo: "**"
alwaysApply: true
---

# File deletion safety

Never use `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, or `Remove-Item` directly. These permanently delete files with no recovery.

## Alternatives

**POSIX (macOS, Linux):**
- `shell-safe-rm` (moves to OS Trash, supports rm flags, recoverable via OS GUI)
- `rip2` / `rip` (moves to graveyard, recoverable via `rip -u`)

**Windows PowerShell:**
- The built-in `rm`, `del`, `rd`, `erase`, `ri`, `Remove-Item` aliases are safe: they recycle to the Recycle Bin. Use them.

**Windows cmd.exe / Git Bash:**
- `rip` (available on PATH, moves to graveyard)

## Rules

- Never invoke `/bin/rm` directly on POSIX. It bypasses the safe-delete protection.
- Never invoke `cmd.exe` or `cmd` on Windows. Always use `pwsh`.
- When a script needs to delete files, use the platform's safe alternative, not raw `rm`.
- If a tool or library calls `rm` internally, that is acceptable; the rule applies to direct agent invocations.
