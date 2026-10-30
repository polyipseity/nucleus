---
description: "Use always: file deletion safety rules. Never use rm or its equivalents directly; use recoverable alternatives. Covers POSIX and Windows."
name: "File Deletion Safety"
applyTo: "**"
alwaysApply: true
---

# File deletion safety

Never use `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, `unlink`, `shred`, or `Remove-Item` directly. These permanently delete files with no recovery. (Deletion-command union across all hosts.)

## Alternatives

**POSIX (macOS, Linux):**
- `shell-safe-rm` (moves to OS Trash, supports rm flags, recoverable via OS GUI)
- `rip2` / `rip` (moves to graveyard, recoverable via `rip -u`)

**PowerShell (all hosts):**
- pwsh safe-delete applies on every host (pwsh is installable on macOS, NixOS, Windows). On Windows it recycles to the Recycle Bin; on POSIX it delegates to `shell-safe-rm`. The aliases `rm`, `del`, `rd`, `erase`, `ri`, `rmdir`, `unlink`, `shred`, `Remove-Item` all route through `Invoke-SafeDelete`.
- The built-in aliases are safe: they recycle to the Recycle Bin on Windows. Use them.

**Windows cmd.exe / Git Bash:**
- `rip` (available on PATH, moves to graveyard)

## Cross-host parity

- Deletion-command union across all hosts: `rm, del, rd, rmdir, erase, ri, unlink, shred, Remove-Item`.
- Interactive blocking covers the union on all hosts (POSIX zsh functions, pwsh aliases).
- PATH shims: POSIX `~/.local/bin/<cmd>` (rm, del, rd, erase, ri, rmdir, unlink, shred) and Windows `%USERPROFILE%\.local\bin\<cmd>.exe` (rm, del, rd, rmdir, erase, ri) delegate to the safe alternative.
- Windows git bash aliases the union to `rip`; cmd intercepts the Windows subset via clink/doskey/PATH shims.
- POSIX pwsh delegates to `shell-safe-rm` (not rip).

## Rules

- Never invoke `/bin/rm` directly on POSIX. It bypasses the safe-delete protection.
- Never invoke `cmd.exe` or `cmd` on Windows. Always use `pwsh`.
- When a script needs to delete files, use the platform's safe alternative, not raw `rm`.
- If a tool or library calls `rm` internally, that is acceptable; the rule applies to direct agent invocations.
