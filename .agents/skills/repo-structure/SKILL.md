---
name: repo-structure
description: Cached knowledge of the nucleus repository architecture, key files, module purposes, and DSC file semantics. Use when working in the nucleus repo to avoid re-discovering foundational structure every session.
---

<!-- Maintainer note: orientation material, not authoring rules. Check AGENTS.md for overlapping content. Use directory listings as authoritative — explicit file lists here go stale.

The module table, host structure, and DSC sections are the core value. Other sections were removed (duplicate AGENTS.md or out-of-scope for structure).

Load this skill via `skill: "repo-structure"` when exploring the repository layout, adding new modules, or modifying host configurations. -->

# Nucleus Repository Structure

## Top-level layout

- `src/flake.nix` — Nix flake entry point. Imports host configs (`src/hosts/*/`) and shared modules (`src/modules/`). Defines `nixosConfigurations`, `darwinConfigurations`, home-manager configs, and `nucleus-*` app packages.
- `src/hosts/` — per-machine configs: `MacBook/` (macOS + nix-darwin), `NixOS/` (Linux), `Windows/` (WinGet DSC YAML + PowerShell apply).
- `src/platforms/` — platform-specific logic shared across hosts on that OS family: `macOS/`, `NixOS/`, `Windows/` (modules, scripts).
- `src/modules/` — cross-host shared Nix modules. List `src/modules/*.nix` for the current set.
- `src/scripts/` — shell scripts called by Nix activation or `nucleus-*` apps.
- `scripts/` — user-facing automation helpers with paired `.sh`/`.ps1` entry points.
- `tests/` — Nix logic tests + Windows Pester DSC validation.

## Key shared modules (`src/modules/`)

| Category           | Modules                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------- |
| Base system        | `core.nix`, `posix-base.nix`, `posix-security.nix`, `posix-sops.nix`, `posix-user-shell.nix` |
| User environment   | `home.nix`, `shell.nix`, `pwsh.nix`, `starship.nix`, `iterm2.nix`                            |
| Developer tools    | `dev-repos.nix`, `editors.nix`, `git.nix`                                                    |
| Security & secrets | `gnupg.nix`, `secrets.nix`                                                                   |
| Services           | `https-proxy.nix`, `camillagui-backend.nix`, `ext-discord-music-rpc.nix`, `logging.nix`      |
| Files & media      | `cloud-drives.nix`, `fonts.nix`, `wallpapers.nix`                                            |
| AI agents          | `agents.nix`, `agent-env-vars.nix`, `agent-host-shell.nix`                                   |
| Env var catalog    | `lib/env-catalog.nix` (catalog + resolution), `lib/managed-paths.nix` (PATH components)      |
| Terminal & shell   | `terminal-activations.nix`                                                                   |
| Other              | `symlinks.nix`                                                              |

Note: `services.json` in `src/modules/` is a data file (service registry), not a Nix module. Host-specific modules (`ntfs-3g.nix`, `camilladsp.nix`, `jellyfin.nix`) live under their host directory.

### Module subdirectories

Additional module files live under these subdirectories:

- `ai/` — AI model selection, litellm config (`default.nix`, `litellm-config.yml`, `models.json`)
- `completions/` — Shell completion files
- `configs/` — Per-application declarative configs (agents, autocorrect, bun, camilladsp, camillagui-backend, cargo, cloud, direnv, discord-music-rpc, git, iterm2, linearmouse, nextest, nix, obsidian, picard, plasma, pwsh, qtpass, ssh, starship, uv, vms, vscode)
- `env/` — Env var catalog introspection module (`default.nix`)
- `lib/` — Support functions (activation-bundle, activation-dag, config-utils, env-catalog, managed-paths, apple-sdk-\*)
- `shell/` — Shell aliases (`aliases.nix`)
- `users/` — User data helpers (`default.nix`)

OS-specific modules live under `src/platforms/<Platform>/modules/` (`macOS/modules/default.nix`, `NixOS/modules/default.nix`).

## Hosts

### macOS (`src/hosts/MacBook/`)

- `default.nix` — nix-darwin entry. Imports modules, defines services, system defaults.
- `defaults.nix` — macOS `defaults write` settings (NSGlobalDomain, dock, Finder, etc.).
- `activation.nix` — nix-darwin activation hooks (Spotlight disable, login items, shell profile).
- `services.nix` — macOS Services (.app bundles for right-click menus). Self-pruning via home.activation. Daemon refresh via `src/scripts/lib/macos-launch-services.sh`.
- `homebrew.nix` — Homebrew packages and taps.
- `cloud-drives.nix` — Cloud drive mount NFS paths.
- `base.nix` — Common config shared with NixOS.
- `linux-builder.nix` — Remote macOS builder.
- `manual-installations.nix` — Manual install setup instructions.
- `ntfs-3g.nix` — NTFS-3G mount support.
- `patches/` — Patches directory.
- `services/` — Launchd service wrappers.
- `raycast-manual-config.md` — Raycast manual config notes.
- `ai.nix`, `sops.nix`, `security.nix`, `networking.nix`, `camilladsp.nix`, `camillagui-backend.nix`, `jellyfin.nix`, `https-proxy.nix`, `service-watchdog.nix`, `vms.nix` — host-specific configs.

### NixOS (`src/hosts/NixOS/`)

- `default.nix` — NixOS entry. Imports modules, defines boot, networking, services.
- `services.nix` — NixOS systemd services.
- `desktop.nix` — Desktop environment config.
- `hardware/` — Hardware-specific configs.
- `activation.nix` — nix-darwin-aligned activation hooks.
- `users.nix` — User definitions.
- `base.nix` — Common config shared with MacBook.
- `ai.nix`, `sops.nix`, `security.nix`, `networking.nix`, `camilladsp.nix`, `camillagui-backend.nix`, `jellyfin.nix`, `https-proxy.nix`, `vms.nix` — host-specific configs.

### Windows (`src/hosts/Windows/`)

- `apply.ps1` — orchestration entry point. Dot-sources `src/platforms/Windows/modules/*.ps1`, applies WinGet DSC YAML.
- `modules/` — reusable PowerShell logic lives under `src/platforms/Windows/modules/`: `setup/` (bootstrap installers), `system/` (daemon services, scheduled tasks), `user/` (Sync-* profile/config scripts), `editors/` (editor configs), `scripts/` (shared scripts), `secrets/` (secret provisioning), `wallpapers/` (wallpaper assets).
- `system/*.dsc.yml` — DSC configs applied system-wide.
- `user/*.dsc.yml` — Per-user DSC configs listed in `src/users/<username>/windows.json` (`dscConfigFiles`).
- `source-builds.json` — Source build definitions for packages not available via WinGet.

## DSC architecture

| Category | Scope                                         | Directory          |
| -------- | --------------------------------------------- | ------------------ |
| System   | Always applied to all users                   | `system/*.dsc.yml` |
| User     | Per-user via `dscConfigFiles` in `src/users/<username>/windows.json` | `user/*.dsc.yml`   |

List the respective directories for the current set of DSC files.
