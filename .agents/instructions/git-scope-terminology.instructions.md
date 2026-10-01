---
description: "Use when authoring or editing git configuration or gitignore files in this repo. Defines the canonical 'global' vs 'user' scope terminology, file layout, and provisioning methods."
name: "Git Scope Terminology"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.ps1, src/users/**, src/modules/configs/git/**"
---

# Git scope terminology

| Term | git flag | POSIX | Windows | Meaning |
| ---------- | ---------- | ------------------------------------------------- | ------------------------------------------------------------------------- | ---- |
| **global** | `--system` | `/etc/gitconfig` | `<Git install>\etc\gitconfig` | Machine-wide, all users. "global" in this repo always means `--system`, the same as "system". |
| **user** | `--global` | `~/.gitconfig` (or `$XDG_CONFIG_HOME/git/config`) | `%USERPROFILE%\.gitconfig` | One user's identity and preferences. |

Rules:

1. Never use "global" to mean `--global`.
2. Only `--system` and `--global` are configured. No `--local`.
3. Gitconfig: both scopes. Gitignore: user scope only, via `core.excludesFile`.

## File layout

Machine-wide: `src/modules/configs/git/<Host>.gitconfig`, one per host name, deployed as a method-1 writable symlink to `/etc/gitconfig` or `<Git install>\etc\gitconfig`. Per-user: `src/users/<username>/git/<Host>.gitconfig` and `<Host>.gitignore`, deployed to `~/.gitconfig` and `~/.config/git/ignore` (`%USERPROFILE%\.config\git\ignore` on Windows), falling back to `src/users/default/git/`. Per-user wins; both platforms fail fast when neither file exists.

POSIX picks the host name through `specialArgs.hostName` and the per-user file through `selectSource` (`src/modules/lib/users-overlay.nix`); Windows reads `$env:NUCLEUS_HOST` and uses `Resolve-UserConfigSource` (`ConfigHelpers.ps1`).

`nucleus apply` runs elevated, so the machine-wide Windows symlink is writable (admins hold `SeCreateSymbolicLinkPrivilege`). A Git for Windows upgrade breaks it and the next apply re-creates it.

## Backups

Every scope a symlink replaces gets a same-folder `.bak`. Create it on first replacement only, never overwrite a stale one (`! -e` guard on POSIX, `Save-RegularFileBackup` on Windows; `home-manager.backupFileExtension = "bak"`). Only the Windows disable path restores it, by removing the symlink and moving the `.bak` back; with no `.bak`, remove the symlink and leave nothing. POSIX activations are always-on, so they back up once and never restore. That asymmetry is intentional.

## Identity

Name, email, and signing key stay out of the symlinked `~/.gitconfig`, because a write lands in the repo tree. They live in `~/.config/git/identity`, reached through `include.path`: written from SOPS secrets by git-identity activation on POSIX, from the user identity env file on Windows.
