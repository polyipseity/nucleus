---
description: "Use when authoring or editing git configuration or gitignore files in this repo. Defines the canonical 'global' vs 'user' scope terminology, file layout, and provisioning methods."
name: "Git Scope Terminology"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.ps1, src/users/**, src/modules/configs/git/**"
---

This file is the single source of truth for git configuration and gitignore naming, file layout, and provisioning in this repo. Every git config or gitignore file, symlink target, activation script, and comment MUST use the terminology and rules below exactly as written.

## 1. Scope terminology (THE canonical convention — never use these words loosely)

| Term       | git flag   | Location (POSIX)                                  | Location (Windows)                                                        | Meaning                                                                                                                                    |
| ---------- | ---------- | ------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **global** | `--system` | `/etc/gitconfig`                                  | `<Git install>\etc\gitconfig` (e.g. `C:\Program Files\Git\etc\gitconfig`) | Machine-wide, all users of the host. The word "global" in this repo ALWAYS means git's `--system` scope. It is the SAME thing as "system". |
| **user**   | `--global` | `~/.gitconfig` (or `$XDG_CONFIG_HOME/git/config`) | `%USERPROFILE%\.gitconfig`                                                | Per-user, one user's identity/preferences.                                                                                                 |

Rules:

- Rule 1: "global" and "system" are synonyms for git `--system`; "global" must never be used to mean `--global`.
- Rule 2: Only these two scopes are configured by this repo. No `--local`, no per-repo config.
- Rule 3: For gitconfig, BOTH scopes are configured (global system gitconfig + per-user gitconfig).
- Rule 4: For gitignore, git has NO global/system scope. A "global gitignore" is implemented per-user via `core.excludesFile` (a per-USER git config key pointing to a user file). Only the user scope exists for gitignore.

## 2. File layout

### Global scope (machine-wide)

`src/modules/configs/git/<Host>.gitconfig` where Host ∈ {MacBook, NixOS, Windows}. One file per host (canonical hostnames: MacBook, NixOS, Windows). Deployed as a method-1 writable symlink on ALL platforms:

- POSIX: `/etc/gitconfig` → `${NUCLEUS_REPO_ROOT}/src/modules/configs/git/<Host>.gitconfig`
- Windows: `<Git install>\etc\gitconfig` → `<NUCLEUS_REPO_ROOT>\src\modules\configs\git\Windows.gitconfig`

### User scope (per-user)

`src/users/<username>/git/<Host>.gitconfig` and `<Host>.gitignore`. Defaults live in `src/users/default/git/` and apply when the per-user file does not exist. Deployed as writable symlinks:

- `~/.gitconfig` → user or default `<Host>.gitconfig`
- `~/.config/git/ignore` (POSIX) / `%USERPROFILE%\.config\git\ignore` (Windows) → user or default `<Host>.gitignore`

Defaults-fallback rule: the per-user directory wins; if `<username>/git/<Host>.gitconfig` (or `.gitignore`) does not exist, `default/git/<Host>.gitconfig` (or `.gitignore`) is used. A user can override by creating their own file. Selection is identical on all platforms: POSIX resolves via `src/modules/lib/users-overlay.nix`, Windows via `Resolve-UserConfigSource` in `ConfigHelpers.ps1` — both fail fast when neither the per-user nor the default file exists.

Hostname derivation: `<Host>` is the canonical hostname (MacBook, NixOS, Windows). POSIX threads it through the flake as `specialArgs.hostName`; Windows derives it at runtime from `$env:NUCLEUS_HOST` (set to `Windows` by `apply.ps1`), mirroring the POSIX `hostName` threading.

## 3. Admin-privilege assumption

`nucleus apply` always runs with admin/elevated privileges on every platform, including Windows. Therefore `<Git install>\etc\gitconfig` IS writable and replaceable (elevated admins hold SeCreateSymbolicLinkPrivilege). Git for Windows upgrades overwrite the file, breaking the symlink — the next apply re-creates it (convergence); shipped defaults are folded into `Windows.gitconfig`.

## 4. Backup/restore lifecycle (ALL platforms)

Every scope where a real config file is replaced by a symlink gets a same-folder backup of the original, visible right next to it: `/etc/gitconfig.bak`, `<install>\etc\gitconfig.bak`, `~/.gitconfig.bak`, `~/.config/git/ignore.bak`. POSIX user scope uses Home Manager's `backupFileExtension = "bak"` — uniform `.bak` across all four scopes.

**Backup-once rule (all platforms).** A `.bak` is created only on first replacement of a pre-existing regular file; a stale `.bak` is never overwritten (first original wins). POSIX: the activation guards the move with `! -e /etc/gitconfig.bak`. Windows: `Save-RegularFileBackup` skips when the `.bak` already exists — the current file stays in place for the symlink to replace, matching POSIX `ln -sf`.

**Restore is a feature of the disable path (by design).** Restore happens only where an enable/disable lifecycle exists (Windows `-Enabled:$false`: remove the symlink, then restore the `.bak` if present). POSIX activations are always-on → backup-on-first-replacement only, no restore path. This asymmetry is intentional — it is NOT a parity gap.

**Missing `.bak` at restore time.** That's OK — assume there was no original config: remove the symlink and leave nothing.

## 5. Identity

Identity (name/email/signingkey) must NOT be written into the symlinked `~/.gitconfig` (that would write into the repo tree). It lives in a separate include file `~/.config/git/identity`, referenced via `include.path` from the user gitconfig. On POSIX it is written from SOPS secrets by the git-identity activation; on Windows from the user's identity env file.

## 6. Provisioning method

All git configs use method 1 (bidirectional writable symlink) per app-config-policy. No parity exceptions.
