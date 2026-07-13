---
name: repo-structure
description: Cached knowledge of the nucleus repository architecture, key files, module purposes, and DSC file semantics. Use when working in the nucleus repo to avoid re-discovering foundational structure every session.
---

<!-- Maintainer note: this skill is reference orientation material, not authoring
     rules. The module table, host structure, and DSC sections are the core value.
     The "Agent customization" and "Scripts" sections were intentionally removed
     because they duplicate AGENTS.md. When editing, check AGENTS.md for
     overlapping content first. -->

## check.sh pitfalls

- `grep -rn` without `-H` on BSD grep (macOS) omits the filename when searching a single file. Always use `grep -Hrn` in check #16's `_check_undoc_supp`.
- `IFS=:` parsing of `grep` output fails silently when filenames are missing, causing `[ "$_ln" -gt 1 ]` to error with "integer expected".
- Path-scoped mode (pre-commit hook) passes individual files as arguments, triggering the BSD grep no-filename issue.
- When filtering grep results inside a `while IFS=: read` loop, use `case` with single-quote detection to skip patterns inside quoted function arguments, not just shell operators.

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
- `services.nix` — macOS Services (.app bundles for right-click menus). Uses a self-pruning home.activation block: removes apps listed in `removedNucleusServices`, deploys from `currentNucleusAppDirs`. Relies on `macos/daemon-refresh.nix` for cache flushes.
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

## Windows modules (`src/hosts/Windows/modules/`)

| File | Purpose |
|------|---------|
| `Set-NucleusService.ps1` | Centralized SCM service lifecycle helpers (`Set-NucleusService`, `Remove-NucleusService`). |

Current user files: `wallpaper`, `screen-saver`, `explorer`, `shell`, `env`, `context-manual`, `context-pdf-opt`.

Current system files: `scheduler`, `developer-mode`, `firewall`, `taskbar`, `computer-name`, `long-paths`, `storage-sense`, `font-substitutes`, `remote-desktop`, `packages`.

## PowerShell type stability notes

When debugging `scripts/check.ps1` locked DSC validation, these gotchas matter:

- **`ConvertFrom-Yaml` (powershell-yaml module)** returns:
  - `PSCustomObject` for YAML mappings
  - `List<object>` (not `Object[]`) for YAML sequences
  - Columnar `OrderedDictionary` on Windows CI: each key maps to an array of values instead of an array of objects
- **`[System.Collections.IList]`** matches `List<object>`, but `[array]` does NOT — always check both.
- **`ForEach-Object` pipeline coercions**: Using `ForEach-Object { ConvertTo-HashtableDeep $_ }` converts `Hashtable` return values to `OrderedDictionary` when the function is recursive. Use a `foreach` loop instead.
- **Single-element array unrolling**: `return @(singleItem)` unrolls to the scalar. Use unary comma: `return ,$arr` or `return ,@(expr)`.
- **Empty array returns**: `return @()` produces no output (assignment becomes `$null`). Use `return ,@()` for an empty array.
