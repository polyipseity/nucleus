---
description: "Use when provisioning or modifying file deletion safety on any host. Documents the two-tier POSIX defense, Windows mechanisms, agent instructions, and cross-host parity."
name: "File Deletion Safety Provisioning"
applyTo: "src/**, scripts/**, tests/**"
alwaysApply: false
---

# File deletion safety provisioning

## POSIX (macOS + NixOS)

- **Packages**: `rip2` via managedPackages (nixpkgs + Homebrew). `safe-rm` via bun global (`safe-rm` npm package, kaelzhang's shell-safe-rm).
- **Interactive shells**: `src/scripts/shell/init.zsh` defines blocking functions for `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, `unlink`, and `shred`; each prints an error and returns 1.
- **Non-interactive shells**: Two defenses:
  1. `rm()` function in `.zshenv` (via `programs.zsh.envExtra`) delegates to `safe-rm`.
  2. `~/.local/bin/rm` wrapper script (via `home.file`) delegates to `safe-rm`. This is the reliable defense for `sh -c "rm ..."` and agent subshells because `~/.local/bin` is on the managed append PATH before system paths.
- **Non-managed shells** (bash, sh, fish): Only the PATH binary defense applies. No alias is injected.

## Windows

- **Packages**: `rip2` via Scoop (`src/modules/scoop-manifests/rip2.json`). `clink` via WinGet DSC (`chrisant996.Clink`).
- **PowerShell (pwsh)**: `Invoke-SafeDelete` function in `src/scripts/shell/profile.ps1` overrides `rm`, `del`, `rd`, `erase`, `ri`, `rmdir`, `unlink`, `shred`, `Remove-Item` on every host: on Windows it recycles through `[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile`/`DeleteDirectory` with `SendToRecycleBin`, and targets that do not resolve to a filesystem item fall back to the original `Remove-Item`; on POSIX it delegates to `shell-safe-rm`, falling back to the original `Remove-Item` when `shell-safe-rm` is absent. Interactive Windows sessions print a tip.
- **cmd.exe**: `Sync-SafeDelete.ps1` writes the Lua filter (`src/platforms/Windows/modules/user/clink/safedel.lua`) to `%LOCALAPPDATA%\clink\safedel.lua`, rewriting `del`, `erase`, `rd`, `rmdir`, `rm` to `rip.exe`. The clink inject AutoRun runs when `clink` resolves on PATH, and the doskey AutoRun is always registered, so a cmd.exe without Clink, or with a Clink that does not load the Lua filter, still routes `del`, `erase`, `rd`, `rmdir`, `rm` to `rip.exe`.
- **Git Bash**: Alias `rm` to `rip` in `~/.bashrc` with interactive detection.
- **PATH shims**: `Sync-SafeDelete.ps1` deploys copies of `rip.exe` as `rm.exe`, `del.exe`, `rd.exe`, `rmdir.exe`, `erase.exe`, `ri.exe` to `%USERPROFILE%\.local\bin` (on managed PATH). Also deploys to `<USER root>\bin`.

## Agent instructions

- `src/users/default/agents/instructions/file-deletion-safety.instructions.md` (alwaysApply): instructs all agents to never use rm or equivalents, use safe alternatives, never invoke `/bin/rm` or `cmd.exe`.

## Agent command blocking

- Guard script `safe-delete-guard` (POSIX sh + PowerShell twin) blocks a deletion reached through a `/bin/rm` path or a `./` relative path, the backslash-escaped spellings, and `cmd`/`cmd.exe` (Windows). A bare `rm` is not in its pattern set, because the interactive alias covers that case and the guard exists to stop the bypasses the alias cannot see. The suite `tests/scripts/safe-delete-guard-tests.sh` pins that split.
- The guard is not a hook: no hook file registers it. Its remaining roles are the PATH command `safe-delete-guard` on POSIX and the `safe-delete-guard.cmd` shim on Windows.
- Every harness that carries a hook file (Claude Code, Copilot, Cursor) gates tool calls through `harness-filter <harness>`, whose `safe-delete` filter applies the same three families plus `settings.unproven` (`deny`, `ask`, or `allow`), so the unproven-redirect question and the audit event reach all of them. Pi and opencode use instructions and extensions only.

## Cross-host parity

- rip2 available on all three hosts (nixpkgs/Homebrew on POSIX, Scoop on Windows).
- safe-rm (kaelzhang) available on POSIX only; Windows uses .NET recycling.
- Interactive blocking message is identical in intent across platforms.
- PATH-based defense works on all platforms.
- Deletion-command union across all hosts: `rm, del, rd, rmdir, erase, ri, unlink, shred, Remove-Item`. Interactive blocking, PATH shims, and agent guards cover the union on every host (not just Windows). POSIX pwsh delegates to `shell-safe-rm` (not rip). Windows git bash aliases the union to `rip`. cmd intercepts the Windows subset via clink/doskey/PATH shims.
