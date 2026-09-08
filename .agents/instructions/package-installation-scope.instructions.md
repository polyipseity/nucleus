---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

User-level only. System-wide prohibited except system infrastructure (nix-darwin `environment.systemPackages`, WinGet DSC registry).

## Cross-host package manager hierarchy

| Scope | macOS (nix-darwin) | NixOS | Windows |
| --- | --- | --- | --- |
| **System packages** | `nixpkgs` via `environment.systemPackages` | `nixpkgs` via NixOS system config | WinGet DSC (`system-packages.dsc.yml`) |
| **User CLI tools** | `nixpkgs` via `home.packages` | `nixpkgs` via `home.packages` | WinGet DSC + Scoop |
| **Global JS packages** | `bun install -g` | `bun install -g` | `bun install -g` |
| **Prebuilt binaries** | N/A | N/A | `cargo-binstall`, Scoop |
| **Python tools** | `uv tool install` | `uv tool install` | `uv tool install` |

## System-install-only tools

Not for interactive dev use:

| Tool | Installed by | Permitted system use |
| --- | --- | --- |
| `bun` | nixpkgs / `Oven-sh.Bun` | `bun add -g` for global JS system packages |
| `cargo` | via `rustup` stable | `cargo-binstall` / `cargo install` for system Rust binaries |
| `rustup` | `pkgs.rustup` (POSIX) / `Rustlang.Rustup` (Win) | toolchain manager; default `none` |
| `uv` | nixpkgs / WinGet | `uv tool install` for system Python |
| `prek` | nixpkgs | system-wide Git hook manager |
| `python` / `pip` | **banned** | all Python via devShell or uv venv |
| `npm` / `npx` / `node` / `corepack` | **banned** | all JS via bun |

## Shell-level enforcement

Blocked tools overridden as shell functions intercepting toward devShell.

- **POSIX (zsh)** — `src/scripts/shell/init.zsh` functions. Flow: `$DIRENV_DIR` → devShell → alternative bundle → error. Educational blocks (`npm`/`npx`/`node`/`corepack`, `pip`/`pip3`, `python`/`python3`) ban directly.
- **PowerShell** — `src/scripts/shell/profile.ps1` (shared, consumed by `pwsh.nix` on POSIX, `Sync-ShellProfile.ps1` on Windows). Same flow.

PATH via `home.sessionPath` (→ `~/.zshenv`), not `initContent` — survives direnv deactivation.

## devShell

Project-specific work. Managed default for repos without direnv/Nix: `bun`, `cargo`/`rustc`, `prek`, `uv`. Auto via direnv with `use flake`; manual via `nix develop`; alternative via managed profile. Windows: WSL or managed PowerShell. POSIX toolchain from `rust-toolchain.toml` (distinct from system `pkgs.rustup`).

## Adding/changing blocked tools

1. Add to `src/modules/shell.nix` (`initContent`), follow existing pattern.
2. Add equivalent to `src/scripts/shell/profile.ps1`.
3. Update this file.
4. If devShell tool, add to `devShells.default` in `src/flake.nix`.

`DIRENV_DIR` pass-through required in every blocking function. Not blocked: `cargo-binstall`, `cargo-cache`, `rustup`, `ruff`, `ty`.

## Tool installation

- **Python:** `uv tool install`. Never `pip install --system`.
- **Rust:** devShell → `cargo-binstall` → `cargo install`. To `~/.cargo/bin`.
- **JavaScript:** `bun install -g` only (POSIX: `agents.nix`; Windows: `Invoke-BunSetup.ps1`). Never `npm install -g`.

## Managed package classification

Declared once in `src/modules/core.nix` `managedPackages`. `category`: `"cli"` → nixpkgs; `"gui"` → Homebrew (cask preferred) on macOS, nixpkgs on NixOS. Ship GUI? Classify `"gui"`.

### Platform restrictions

Platform-specific packages add `platforms`:

```nix
iterm2 = {
  category = "gui";
  platforms = ["darwin"];
  homebrew = { kind = "cask"; name = "iterm2"; };
  nixpkgs = "iterm2";
};
```

Darwin-only: `iterm2`, `rectangle`, `stats`, `utm`. Homebrew-only: use `missingNixAttrs`.

### Adding a managed package

1. Add to `managedPackages` in `core.nix` (alphabetical).
2. `platforms = ["darwin"]` if macOS-only.
3. Choose category.
4. Remove duplicates from `NixOS/desktop.nix` if needed.

## Violations

| Pattern | Fix |
| --- | --- |
| `sudo bun install -g` | Remove `sudo` |
| `pip install --system` | `uv tool install` or devShell |
| `npm install -g` / `npx` (unmanaged) | `bun install -g` / `bun x` |
| Installing to `/usr/local/bin` | User-level tool dirs |
| `cargo install` in setup.sh | devShell or `cargo-binstall` |
| `Install-Module -Scope Machine` | `-Scope CurrentUser` |
