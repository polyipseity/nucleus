---
description: "Use when authoring or editing git configuration or gitignore files."
name: "Git Scope Terminology"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.ps1, src/users/**, src/modules/configs/git/**"
---

# Git scope terminology

"global" always means `--system` (machine-wide: `/etc/gitconfig`, `<Git install>\etc\gitconfig`); "user" means `--global` (`~/.gitconfig`, Windows `%USERPROFILE%\.gitconfig`). Never use "global" for `--global`, never use `--local`, and configure gitignore only at user scope via `core.excludesFile`.

Machine gitconfig lives in `src/modules/configs/git/<Host>.gitconfig`; user config and gitignore live in `src/users/<username>/git/` with `src/users/default/` fallback. POSIX resolves through `specialArgs.hostName` and `selectSource`, Windows through `$env:NUCLEUS_HOST` and `Resolve-UserConfigSource`. Windows apply is elevated so the system symlink is writable; Git upgrades break it and apply recreates it.

Every replaced scope gets one same-folder `.bak`, never overwritten; only Windows disable restores it, with no `.bak` leaving no file. POSIX backs up once and never restores. Name, email, and signing key live in `~/.config/git/identity` through `include.path`, not the symlinked gitconfig.

Details: `.agents/skills/nucleus-platform-reference/references/git-scope-terminology.md`.
