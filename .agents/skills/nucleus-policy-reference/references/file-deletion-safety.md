---
description: "Use when provisioning or modifying file deletion safety on any host."
name: "File Deletion Safety Provisioning"
applyTo: "src/**, scripts/**, tests/**"
alwaysApply: false
---

# File deletion safety provisioning

## POSIX

Packages: `rip2` via managedPackages (nixpkgs and Homebrew), `safe-rm` via bun (kaelzhang package). Interactive shells (`src/scripts/shell/init.zsh`) block `rm`, `del`, `rd`, `rmdir`, `erase`, `ri`, `unlink`, `shred` with an error and return 1.

Non-interactive shells have two defenses: a `rm()` function in `.zshenv` via `programs.zsh.envExtra` delegating to `safe-rm`, and a `~/.local/bin/rm` wrapper via `home.file` doing the same. The PATH wrapper is the reliable path for `sh -c "rm ..."` and agent subshells because managed append PATH puts `~/.local/bin` before system paths. Non-managed shells (bash, sh, fish) get only the PATH binary, no alias.

## Windows

`rip2` comes from Scoop (`src/modules/scoop-manifests/rip2.json`), `clink` from WinGet DSC (`chrisant996.Clink`). `Invoke-SafeDelete` in `src/scripts/shell/profile.ps1` overrides `rm`, `del`, `rd`, `erase`, `ri`, `rmdir`, `unlink`, `shred`, `Remove-Item` on every host. Windows recycles through `[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile`/`DeleteDirectory` with `SendToRecycleBin`, falling back to original `Remove-Item` for non-filesystem targets; POSIX delegates to `safe-rm` and falls back when absent. Interactive Windows sessions print a tip.

`Sync-SafeDelete.ps1` writes the clink Lua filter (`src/platforms/Windows/modules/user/clink/safedel.lua`) to `%LOCALAPPDATA%\clink\safedel.lua`, rewriting `del`, `erase`, `rd`, `rmdir`, `rm` to `rip.exe`. The clink AutoRun loads it when clink resolves on PATH; the doskey AutoRun is always registered, so a cmd.exe without clink still routes those words to rip. It also copies `rip.exe` as `rm.exe`, `del.exe`, `rd.exe`, `rmdir.exe`, `erase.exe`, `ri.exe` into `%USERPROFILE%\.local\bin` and `<USER root>\bin`.

`<USER root>\state\safe-delete\shims.json` records `version`, the `ripHash` of the source `rip.exe`, and every deployed shim path in sorted order. Copies are files, not symlinks, so the manifest is the proof: the filter accepts a word only when the resolved shim is listed and its SHA256 equals `ripHash`. A missing, stale, or edited manifest leaves it unproven.

## Graveyard

`RIP_GRAVEYARD` is user-scope in the env catalog and points to `<USER root>/state/rip/graveyard` on every host (macOS `~/Library/Application Support/nucleus/...`, NixOS `~/.local/share/nucleus/...`, Windows `%LOCALAPPDATA%\nucleus\...`). POSIX `ensureRipGraveyard` and `Sync-SafeDelete.ps1` create it because activations, cron, and elevated processes may lack the user environment. `nucleus-gc graveyard` reports path, entry count, total size (`du -sk` blocks on POSIX), and oldest entry; it never deletes. Nothing migrates entries from the old `$TMPDIR` graveyard.

## Agents and guards

`src/users/default/agents/instructions/file-deletion-safety.instructions.md` tells agents never to use rm or equivalents, to use safe alternatives, and never to invoke `/bin/rm` or `cmd.exe`.

The guard is `src/scripts/notify/filters/safe-delete.ts` in `--hook` mode, exposed as `nucleus-utils harness check-deletion`: PATH command on POSIX, `.cmd` launcher written by `Sync-SafeDelete.ps1` on Windows. It denies native paths, `cmd`/`cmd.exe` in command position, and `find -delete`. A bare word is proven or unproven by `settings.unproven` (`ask` default, `deny`, `allow`); `rip` is a no-match allow. `-NoProfile` or an unambiguous prefix such as `-nop` on Windows is unproven. A heredoc body is data; `find -exec rm {} \;` is analyzed as a command; a backslash-escaped word resolves through PATH. `tests/scripts/safe-delete-guard-tests.sh` pins the split.

No hook registers the guard. It remains a `check-deletion` subcommand and the shared policy used by `harness decide-call`. Hook-bearing harnesses (Claude Code, Copilot, Cursor) run the same filter and apply `settings.unproven`; Pi and opencode use instructions and extensions only.

## Parity

rip2 on all hosts; one managed rip graveyard per host under the USER root; safe-rm only on POSIX, .NET recycling on Windows; identical interactive blocking intent; PATH defense everywhere. Deletion union: `rm, del, rd, rmdir, erase, ri, unlink, shred, Remove-Item`. Interactive blocks, shims, and agent guards cover the union on every host. POSIX pwsh delegates to `safe-rm`, not rip; Windows git bash aliases the union to rip; cmd intercepts the Windows subset via clink, doskey, and shims.
