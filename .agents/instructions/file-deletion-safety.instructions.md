---
description: "Use when provisioning or modifying file deletion safety on any host. Documents the two-tier POSIX defense, Windows mechanisms, agent instructions, and cross-host parity."
name: "File Deletion Safety Provisioning"
applyTo: "src/**, scripts/**, tests/**"
alwaysApply: false
---

# File deletion safety provisioning

## POSIX (macOS + NixOS)

- **Packages**: `rip2` via managedPackages (nixpkgs + Homebrew). `safe-rm` via bun global (`safe-rm` npm package, kaelzhang's shell-safe-rm).
- **Interactive shells**: `rm()` function in `src/scripts/shell/init.zsh` prints an error and blocks. Aliases `del`, `rmdir` are not overridden (only `rm` is blocked interactively).
- **Non-interactive shells**: Two defenses:
  1. `rm()` function in `.zshenv` (via `programs.zsh.envExtra`) delegates to `safe-rm`.
  2. `~/.local/bin/rm` wrapper script (via `home.file`) delegates to `safe-rm`. This is the reliable defense for `sh -c "rm ..."` and agent subshells because `~/.local/bin` is on the managed append PATH before system paths.
- **Non-managed shells** (bash, sh, fish): Only the PATH binary defense applies. No alias is injected.

## Windows

- **Packages**: `rip2` via Scoop (`src/modules/scoop-manifests/rip2.json`). `clink` via WinGet DSC (`chrisant996.Clink`).
- **PowerShell (pwsh)**: `Invoke-SafeDelete` function in `src/scripts/shell/profile.ps1` overrides `rm`, `del`, `rd`, `erase`, `ri`, `Remove-Item`. Delegates to `[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile/Directory` with `SendToRecycleBin`. Interactive sessions print a tip; non-interactive sessions silently recycle.
- **cmd.exe**: Clink Lua filter (`src/platforms/Windows/modules/user/clink/safedel.lua`) deployed to `%LOCALAPPDATA%\clink\safedel.lua`. Intercepts `del`, `erase`, `rd`, `rmdir`, `rm` and redirects to `rip.exe`. Vanilla cmd fallback via doskey AutoRun registry.
- **Git Bash**: Alias `rm` to `rip` in `~/.bashrc` with interactive detection.
- **PATH shims**: `Sync-SafeDelete.ps1` deploys copies of `rip.exe` as `rm.exe`, `del.exe`, `rd.exe`, `rmdir.exe`, `erase.exe`, `ri.exe` to `%USERPROFILE%\.local\bin` (on managed PATH). Also deploys to `<USER root>\bin`.

## Agent instructions

- `src/users/default/agents/instructions/file-deletion-safety.instructions.md` (alwaysApply): instructs all agents to never use rm or equivalents, use safe alternatives, never invoke `/bin/rm` or `cmd.exe`.

## Agent command blocking

- Guard script `safe-delete-guard` (POSIX sh + PowerShell twin) blocks `/bin/rm`, `cmd`/`cmd.exe` (Windows), and direct `rm` invocations.
- Deployed as PreToolUse hooks for Claude Code, Copilot, Cursor, OpenCode. Pi uses instructions only.

## Cross-host parity

- rip2 available on all three hosts (nixpkgs/Homebrew on POSIX, Scoop on Windows).
- safe-rm (kaelzhang) available on POSIX only; Windows uses .NET recycling.
- Interactive blocking message is identical in intent across platforms.
- PATH-based defense works on all platforms.
