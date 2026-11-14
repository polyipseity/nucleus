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
- **Shim manifest**: `Sync-SafeDelete.ps1` writes `<USER root>\state\safe-delete\shims.json` holding `version`, the `ripHash` of the `rip.exe` the copies came from, and every deployed shim path, in sorted order. The copies are files rather than symlinks, so the manifest is the only proof of what they are: the filter proves a word only when the resolved shim is listed and its SHA256 equals `ripHash`, and a missing, stale, or edited manifest leaves the word unproven.

## rip graveyard

`rip` moves a deletion aside instead of removing it, so the graveyard is the undo window. `RIP_GRAVEYARD` in the env catalog, at user scope, sends the user's processes to `<USER root>/state/rip/graveyard` on every host: `~/Library/Application Support/nucleus/state/rip/graveyard` on macOS, `~/.local/share/nucleus/state/rip/graveyard` on NixOS, `%LOCALAPPDATA%\nucleus\state\rip\graveyard` on Windows. POSIX activation creates it (`ensure-rip-graveyard`) and `Sync-SafeDelete.ps1` creates it on Windows, because an activation, cron job, or elevated process does not necessarily carry the user environment, and an unset variable leaves rip on its per-session `$TMPDIR` default. `nucleus-gc graveyard` reports the path, entry count, total size (`du -sk` blocks on POSIX) and oldest entry, and never deletes, because retention is the owner's decision. Nothing migrates entries left under the older `$TMPDIR` graveyard.

## Agent instructions

- `src/users/default/agents/instructions/file-deletion-safety.instructions.md` (alwaysApply): instructs all agents to never use rm or equivalents, use safe alternatives, never invoke `/bin/rm` or `cmd.exe`.

## Agent command blocking

- Guard script `safe-delete-guard` is the shared policy `src/scripts/notify/filters/safe-delete.ts` in its `--hook` mode: on POSIX it is the PATH command, on Windows a `.cmd` launcher `Sync-SafeDelete.ps1` writes. It denies a deletion spelled as a native path (`/bin/rm`, `C:\BIN\RM.exe`), `cmd`/`cmd.exe` in command position, and `find -delete`. A bare deletion word is proven or unproven, and `settings.unproven` decides the unproven case; `rip` is not a deletion word at all, so `rip -rf x` is a no-match allow. On Windows a command carrying `-NoProfile` or an unambiguous prefix such as `-nop` is unproven, because that session never loaded the profile that rewrites the cmdlets. A heredoc body is data and a `find -exec` command is analyzed as a command, so `find . -exec rm {} \;` follows the same proof as the bare word. A backslash-escaped word resolves through PATH like the bare word, because the escape bypasses the shell alias rather than the wrapper. The suite `tests/scripts/safe-delete-guard-tests.sh` pins that split.
- The guard is not a hook: no hook file registers it. Its remaining roles are the PATH command `safe-delete-guard` on POSIX and the `safe-delete-guard.cmd` launcher on Windows.
- Every harness that carries a hook file (Claude Code, Copilot, Cursor) gates tool calls through `harness-filter <harness>`, whose `safe-delete` filter runs that same file as a filter process and applies those rules plus `settings.unproven` (`deny`, `ask`, or `allow`), so the unproven-redirect question and the audit event reach all of them. Pi and opencode use instructions and extensions only.

## Cross-host parity

- rip2 available on all three hosts (nixpkgs/Homebrew on POSIX, Scoop on Windows).
- The rip graveyard is one managed directory per host under the nucleus USER root, set by `RIP_GRAVEYARD`.
- safe-rm (kaelzhang) available on POSIX only; Windows uses .NET recycling.
- Interactive blocking message is identical in intent across platforms.
- PATH-based defense works on all platforms.
- Deletion-command union across all hosts: `rm, del, rd, rmdir, erase, ri, unlink, shred, Remove-Item`. Interactive blocking, PATH shims, and agent guards cover the union on every host (not just Windows). POSIX pwsh delegates to `shell-safe-rm` (not rip). Windows git bash aliases the union to `rip`. cmd intercepts the Windows subset via clink/doskey/PATH shims.
