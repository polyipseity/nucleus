---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

User-level only. System-wide is limited to system infrastructure: nix-darwin `environment.systemPackages`, the NixOS system config, and the WinGet DSC registry.

| Scope | macOS (nix-darwin) | NixOS | Windows |
| --- | --- | --- | --- |
| System packages | `nixpkgs` via `environment.systemPackages` | `nixpkgs` via NixOS system config | WinGet DSC (`system-packages.dsc.yml`) |
| User CLI tools | `nixpkgs` via `home.packages` | `nixpkgs` via `home.packages` | WinGet DSC + Scoop |
| Global JS packages | `bun install -g` | `bun install -g` | `bun install -g` |
| Prebuilt binaries | N/A | N/A | `cargo-binstall`, Scoop |
| Python tools | `uv tool install` | `uv tool install` | `uv tool install` |

Install form: Python via `uv tool install`, never `pip install --system`. Rust via devShell, then `cargo-binstall`, then `cargo install`, landing in `~/.cargo/bin`. JS via `bun install -g` only, never `npm install -g` (POSIX `agents.nix`, Windows `Invoke-BunSetup.ps1`).

## System-install-only tools

Not for interactive dev use:

| Tool | Installed by | Permitted system use |
| --- | --- | --- |
| `bun` | nixpkgs / `Oven-sh.Bun` | `bun add -g` for global JS system packages |
| `cargo` | via `rustup` stable | `cargo-binstall` / `cargo install` for system Rust binaries |
| `rustup` | `pkgs.rustup` (POSIX) / `Rustlang.Rustup` (Win) | toolchain manager; default `none` |
| `uv` | nixpkgs / WinGet | `uv tool install` for system Python |
| `prek` | nixpkgs | system-wide Git hook manager |
| `python` / `pip` | banned | all Python via devShell or uv venv |
| `npm` / `npx` / `node` / `corepack` | banned | all JS via bun |

## Shell-level enforcement

Blocked tools are overridden as shell functions that intercept toward devShell: `$DIRENV_DIR` → devShell → alternative bundle → error. Educational blocks (`npm`/`npx`/`node`/`corepack`, `pip`/`pip3`, `python`/`python3`) ban outright.

- POSIX zsh: `src/scripts/shell/init.zsh`.
- PowerShell: `src/scripts/shell/profile.ps1` (shared, consumed by `pwsh.nix` on POSIX and `Sync-ShellProfile.ps1` on Windows).

`DIRENV_DIR` pass-through is required in every blocking function. Not blocked: `cargo-binstall`, `cargo-cache`, `rustup`, `ruff`, `ty`.

PATH goes through `home.sessionPath` (→ `~/.zshenv`), not `initContent`, so it survives direnv deactivation.

To change the blocked set: edit `initContent` in `src/modules/shell/default.nix` and the matching block in `profile.ps1`, update this file, and add devShell tools to `devShells.default` in `src/flake.nix`.

## Managed package classification

Declared once in `managedPackages` in `src/modules/core.nix`, alphabetically. `category: "cli"` → nixpkgs; `"gui"` → Homebrew cask on macOS, nixpkgs on NixOS, so an app shipping a GUI component is `"gui"`. Platform-specific entries add `platforms` (`platforms = [ "darwin" ]`); Homebrew-only entries set `missingNixAttrs`. Remove duplicates from `NixOS/desktop.nix`.

An entry whose bare `nixpkgs` attr is not the derivation to deploy carries `nixpkgsPackage`, with `nixpkgs` still required as the availability probe. Never contribute a second derivation for the same binary: `buildEnv` collides on it, nix-darwin's `system-path` keeps the first, and Home Manager's `home-manager-path` refuses to build, so replace the entry instead (`pass` deploys `pkgs.pass.withExtensions (extensions: [ extensions.pass-otp ])`).

Dropping a tap-qualified Homebrew formula leaves its tap to outlive it: nix-homebrew untaps undeclared taps before `brew bundle --zap` cleanup, which then aborts activation on an orphaned formula after the profile already moved. Uninstall the formula on every MacBook before the commit that drops the tap; no migration shim belongs in the repo.

## Violations

| Pattern | Fix |
| --- | --- |
| `sudo bun install -g` | Remove `sudo` |
| `pip install --system` | `uv tool install` or devShell |
| `npm install -g` / `npx` (unmanaged) | `bun install -g` / `bun x` |
| Installing to `/usr/local/bin` | User-level tool dirs |
| `cargo install` in setup.sh | devShell or `cargo-binstall` |
| `Install-Module -Scope Machine` | `-Scope CurrentUser` |
