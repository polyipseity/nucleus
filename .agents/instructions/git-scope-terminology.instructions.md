---
description: "Use when authoring or editing git configuration or gitignore files in this repo. Defines the canonical 'global' vs 'user' scope terminology, file layout, and provisioning methods."
name: "Git Scope Terminology"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.ps1, src/users/**, src/modules/configs/git/**"
---

# Git scope terminology

Canonical rules for git config and gitignore naming, layout, and provisioning.

## 1. Scope terminology

| Term | git flag | Location (POSIX) | Location (Windows) | Meaning |
| ---------- | ---------- | ------------------------------------------------- | ------------------------------------------------------------------------- | ---- |
| **global** | `--system` | `/etc/gitconfig` | `<Git install>\etc\gitconfig` (e.g. `C:\Program Files\Git\etc\gitconfig`) | Machine-wide, all users. "global" in this repo always means `--system` — same as "system". |
| **user** | `--global` | `~/.gitconfig` (or `$XDG_CONFIG_HOME/git/config`) | `%USERPROFILE%\.gitconfig` | Per-user, one user's identity/preferences. |

Rules:

1. "global" = git `--system`; never use "global" to mean `--global`.
2. Only `--system` and `--global` are configured. No `--local`.
3. Gitconfig: both scopes configured (system + per-user).
4. Gitignore: only user scope exists. "Global gitignore" is per-user via `core.excludesFile` (a `--global` git config key).

## 2. File layout

### Global scope (machine-wide)

`src/modules/configs/git/<Host>.gitconfig` where Host ∈ {MacBook, NixOS, Windows}. Deployed as method-1 writable symlink on all platforms:

- POSIX: `/etc/gitconfig` → `${NUCLEUS_REPO_ROOT}/src/modules/configs/git/<Host>.gitconfig`
- Windows: `<Git install>\etc\gitconfig` → `<NUCLEUS_REPO_ROOT>\src\modules\configs\git\Windows.gitconfig`

### User scope (per-user)

`src/users/<username>/git/<Host>.gitconfig` and `<Host>.gitignore`. Defaults in `src/users/default/git/` when per-user file is absent. Deployed as writable symlinks:

- `~/.gitconfig` → user or default `<Host>.gitconfig`
- `~/.config/git/ignore` (POSIX) / `%USERPROFILE%\.config\git\ignore` (Windows) → user or default `<Host>.gitignore`

Per-user wins; absent per-user falls back to `default/git/`. Selection is identical across platforms: POSIX via `src/modules/lib/users-overlay.nix`, Windows via `Resolve-UserConfigSource` in `ConfigHelpers.ps1`. Both fail fast when neither exists.

Hostname derivation: POSIX threads `<Host>` through the flake as `specialArgs.hostName`; Windows derives at runtime from `$env:NUCLEUS_HOST`.

## 3. Admin-privilege assumption

`nucleus apply` always runs elevated. `<Git install>\etc\gitconfig` is writable (elevated admins hold `SeCreateSymbolicLinkPrivilege`). Git for Windows upgrades break the symlink; next apply re-creates it. Shipped defaults are folded into `Windows.gitconfig`.

## 4. Backup/restore lifecycle (ALL platforms)

Each scope where a symlink replaces a real file gets a same-folder `.bak`: `/etc/gitconfig.bak`, `<install>\etc\gitconfig.bak`, `~/.gitconfig.bak`, `~/.config/git/ignore.bak`. POSIX user scope uses HM `backupFileExtension = "bak"`.

**Backup-once rule.** `.bak` created only on first replacement; stale `.bak` never overwritten. POSIX: `! -e /etc/gitconfig.bak` guard. Windows: `Save-RegularFileBackup` skips when `.bak` exists.

**Restore only in disable path.** Windows `-Enabled:$false` removes symlink, restores `.bak` if present. POSIX activations are always-on — backup-on-first-replacement only, no restore. Intentional asymmetry, not a parity gap.

**Missing `.bak` at restore.** Remove symlink, leave nothing.

## 5. Identity

Identity (name/email/signingkey) must not go into the symlinked `~/.gitconfig` (writes into repo tree). Lives in `~/.config/git/identity`, referenced via `include.path`. POSIX: written from SOPS secrets by git-identity activation. Windows: from user identity env file.

## 6. Provisioning method

All git configs use method 1 (bidirectional writable symlink) per app-config-policy.
