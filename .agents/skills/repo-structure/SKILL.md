---
name: repo-structure
description: Cached knowledge of the nucleus repository architecture, key files, module purposes, and DSC file semantics. Use when working in the nucleus repo to avoid re-discovering foundational structure every session.
---

# Nucleus Repository Structure

## Top-level layout

- `src/flake.nix` — Nix flake entry point. Imports host configs (`src/hosts/*/`) and shared modules (`src/modules/`). Defines `nixosConfigurations`, `darwinConfigurations`, home-manager configs, and `nucleus-*` app packages.
- `src/hosts/` — per-machine configs: `MacBook/` (macOS + nix-darwin), `NixOS/` (Linux), `Windows/` (WinGet DSC YAML + PowerShell apply).
- `src/modules/` — shared Nix modules used across hosts. Key modules listed below.
- `src/scripts/` — shell scripts called by Nix activation or `nucleus-*` apps.
- `scripts/` — user-facing automation helpers with paired `.sh`/`.ps1` entry points.
- `tests/` — Nix logic tests + Windows Pester DSC validation.

## Key shared modules (`src/modules/`)

| Module | Purpose |
|--------|---------|
| `core.nix` | Base system config imported by all hosts. Sets common Nixpkgs config, system-level packages, services. |
| `posix-base.nix` | POSIX-only (macOS + NixOS) base: nix-index, shell history, file systems, activation script, symlinks. |
| `posix-security.nix` | POSIX security: GPG agent, SSH agent, firewall, DoH, fail2ban (NixOS only). |
| `posix-sops.nix` | SOPS + Age key management for POSIX hosts. |
| `posix-user-shell.nix` | POSIX user shell init: zsh aliases, env vars, prompt. |
| `macos.nix` | macOS-specific: dock, Finder, trackpad, keyboard, screenshots, menubar. |
| `linux.nix` | Linux-specific settings. |
| `home.nix` | Home Manager entry point for user-level config. |
| `shell.nix` | Common shell config (zsh aliases like `-gs-pdf-opt-*`, env vars). |
| `pwsh.nix` | PowerShell config for POSIX hosts (aliases, prompt, functions). |
| `cloud-drives.nix` | Cloud drive mounts (macOS NFS + replicas, Windows cloud drive replica sync). |
| `fonts.nix` | Font packages configuration. |
| `editors.nix` | Editor settings (VS Code config path, extensions). |
| `git.nix` | Git config (user name/email from secrets, aliases, delta). |
| `gnupg.nix` | GPG agent config for POSIX. |
| `secrets.nix` | SOPS-managed secrets decryption config. |
| `wallpapers.nix` | Managed wallpaper assets (decrypted, not ad-hoc files). |
| `agents.nix` | AI agent skill/agent provisioning. |
| `https-proxy.nix` | HTTPS proxy service (Caddy) config. |
| `logging.nix` | Log rotation and persistence. |
| `services.json` | Service registry (canonical list of `nucleus-*` commands). |

## Hosts

### macOS (`src/hosts/MacBook/`)

- `default.nix` — nix-darwin entry. Imports modules, defines services, system defaults.
- `defaults.nix` — macOS `defaults write` settings (NSGlobalDomain, dock, Finder, etc.).
- `services.nix` — macOS Services (.app bundles for right-click menus). Uses a self-pruning home.activation block: removes apps listed in `removedNucleusAppDirs`, deploys from `currentNucleusAppDirs`. To remove a service: delete deploy logic + move app dir between these two lists.
- `activation.nix` — nix-darwin activation script hooks (Spotlight disable, login items, shell profile).

### NixOS (`src/hosts/NixOS/`)

- `default.nix` — NixOS entry. Imports modules, defines boot, networking, services.
- `services.nix` — NixOS systemd services.

### Windows (`src/hosts/Windows/`)

- `apply.ps1` — orchestration entry point. Dot-sources `modules/*.ps1`, applies WinGet DSC YAML.
- `modules/` — reusable PowerShell logic (Sync-*, Invoke-* functions).
- `system/*.dsc.yml` — universal DSC configs applied to all users.
- `user/*.dsc.yml` — per-user DSC configs listed in `users.json`.

## DSC architecture

| Category | Files | Scope |
|----------|-------|-------|
| System | `system/*.dsc.yml` | Always applied to all users |
| User | `user/*.dsc.yml` | Per-user via `dscConfigFiles` in `users.json` |

Current user files: `wallpaper`, `screen-saver`, `explorer`, `shell`, `env`, `context-manual`, `context-pdf-opt`.

Current system files: `scheduler`, `developer-mode`, `firewall`, `taskbar`, `computer-name`, `long-paths`, `storage-sense`, `font-substitutes`, `remote-desktop`, `packages`.

## Scripts

- All `nucleus-*` commands are apps defined in `src/flake.nix` and callable from any directory.
- Paired `.sh`/`.ps1` entry points under `scripts/` with identical names: `apply`, `ai-sync`, `bootstrap`, `bump-lockfile`, `check`, `cloud-setup`, `gc`, `health-check`, `replica-reset`, `replica-sync`, `update`, `vm-setup`, `svc`, `test`.

## Agent customization

- `.agents/instructions/*.instructions.md` — file-type-scoped rules loaded automatically.
- `.agents/prompts/*.prompt.md` — reusable workflow prompts (`implement-plan`, `commit-staged`).
- `.agents/skills/<skill>/` — skill bundles for repeatable operations.
- `AGENTS.md` — canonical workspace-wide source of truth (keep short).
