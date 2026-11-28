---
description: "Use when authoring or editing git configuration or gitignore files."
name: "Git Scope Terminology"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.ps1, src/users/**, src/modules/configs/git/**"
---

# Git scope terminology

| Term | git flag | POSIX | Windows | Meaning |
| --- | --- | --- | --- | --- |
| global | `--system` | `/etc/gitconfig` | `<Git install>\etc\gitconfig` | Machine-wide, all users; "global" always means `--system` here |
| user | `--global` | `~/.gitconfig` or `$XDG_CONFIG_HOME/git/config` | `%USERPROFILE%\.gitconfig` | One user's identity and preferences |

Never use "global" for `--global`. Configure only `--system` and `--global`, never `--local`. Gitconfig uses both scopes; gitignore uses user scope through `core.excludesFile`.

## File layout

Machine-wide: `src/modules/configs/git/<Host>.gitconfig`, one per host, deployed as a method-1 writable symlink to `/etc/gitconfig` or `<Git install>\etc\gitconfig`. Per-user: `src/users/<username>/git/<Host>.gitconfig` and `<Host>.gitignore`, deployed to `~/.gitconfig` and `~/.config/git/ignore` (`%USERPROFILE%\.config\git\ignore` on Windows), falling back to `src/users/default/git/`. Per-user wins; both platforms fail fast when neither exists.

POSIX picks the host through `specialArgs.hostName` and the user file through `selectSource` (`src/modules/lib/users-overlay.nix`). Windows reads `$env:NUCLEUS_HOST` and uses `Resolve-UserConfigSource` (`ConfigHelpers.ps1`).

`nucleus apply` runs elevated, so the Windows machine-wide symlink is writable (admins hold `SeCreateSymbolicLinkPrivilege`). A Git for Windows upgrade breaks it; the next apply recreates it.

## Backups

Every scope a symlink replaces gets a same-folder `.bak`, created on first replacement only and never overwritten (`! -e` guard, `Save-RegularFileBackup`, `home-manager.backupFileExtension = "bak"`). Only the Windows disable path restores it by removing the symlink and moving the `.bak` back; with no `.bak`, remove the symlink and leave nothing. POSIX activations are always-on, so they back up once and never restore. The asymmetry is intentional.

## Identity

Name, email, and signing key stay out of the symlinked `~/.gitconfig` because a write would land in the repo tree. They live in `~/.config/git/identity`, reached through `include.path`: written from SOPS secrets by git-identity activation on POSIX, from the user identity env file on Windows.
