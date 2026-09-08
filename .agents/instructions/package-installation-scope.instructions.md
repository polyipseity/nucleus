---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

All tools and libraries at user-level only. System-wide prohibited except system infrastructure (nix-darwin `environment.systemPackages`, WinGet DSC registry).

## Cross-host package manager hierarchy

| Scope | macOS (nix-darwin) | NixOS | Windows |
| --- | --- | --- | --- |
| **System packages** | `nixpkgs` via `environment.systemPackages` | `nixpkgs` via NixOS system config | WinGet DSC (`system-packages.dsc.yml`) |
| **User CLI tools** | `nixpkgs` via `home.packages` | `nixpkgs` via `home.packages` | WinGet DSC (`user.dsc.yml`, `user-env.dsc.yml`) + Scoop |
| **Global JS packages** | `bun install -g` | `bun install -g` | `bun install -g` |
| **Prebuilt binaries** | N/A | N/A | `cargo-binstall`, Scoop |
| **Python tools** | `uv tool install` | `uv tool install` | `uv tool install` |

## System-install-only tools

Global installs for system package management only — not for interactive dev use:

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

Each blocked tool overridden as shell function that intercepts and errors toward devShell.

- **POSIX (zsh)** — `src/scripts/shell/init.zsh` functions in `programs.zsh.initContent`. Flow: check `$DIRENV_DIR` → devShell binary → alternative bundle → error. Educational blocks (`npm`/`npx`/`node`/`corepack`, `pip`/`pip3`, `python`/`python3`) ban directly.
- **PowerShell** — `src/scripts/shell/profile.ps1`: shared profile, consumed by `src/modules/pwsh.nix` (POSIX) and `Sync-ShellProfile.ps1` (Windows). Same `$env:DIRENV_DIR` flow.

PATH via `home.sessionPath` (→ `~/.zshenv`), not `initContent` — survives direnv deactivation.

## devShell

For project-specific work. Repos without direnv/Nix get managed default: `bun`, `cargo`/`rustc`, `prek`, `uv`.

- **POSIX auto (preferred):** direnv with `use flake` in `.envrc`.
- **POSIX manual:** `nix develop` from repo root.
- **POSIX alternative:** managed shell profile outside `.envrc`.
- **Windows:** `nix develop` via WSL or managed PowerShell profile.

POSIX: `pkgs.rust-bin.fromRustupToolchainFile` assembles from `rust-toolchain.toml` — distinct from system `pkgs.rustup`. Windows: rustup reads `rust-toolchain.toml` natively.

## Adding/changing blocked tools

1. Add blocking function to `src/modules/shell.nix` (`initContent`), follow existing pattern.
2. Add equivalent to `src/scripts/shell/profile.ps1`.
3. Update this file.
4. If devShell tool, add to `devShells.default` in `src/flake.nix` (alphabetical).

## Invariants

- `DIRENV_DIR` pass-through required in every blocking function.
- Alternative environment matches `devShells.default` baseline: `bun`, `cargo`, `prek`, `rustc`, `uv`.
- Not blocked: `cargo-binstall`, `cargo-cache` (system Rust mgmt), `rustup` (toolchain manager), `ruff`, `ty` (editor linting).

## Tool installation patterns

- **Python:** `uv tool install`. Never `pip install --system`.
- **Rust:** devShell → `cargo-binstall` → `cargo install`. Installs to `~/.cargo/bin`.
- **JavaScript:** `bun install -g` only. Managed via `agents.nix` (POSIX) or `Invoke-BunSetup.ps1` (Windows). Never `npm install -g`.

## Managed package classification

Each cross-platform package declared once in `src/modules/core.nix` `managedPackages` with metadata. `category` selects backend: `"cli"` → nixpkgs; `"gui"` → Homebrew (cask preferred) on macOS, nixpkgs on NixOS. Ship GUI component? Classify `"gui"`.

### Platform restrictions

Platform-specific packages add `platforms` field:

```nix
iterm2 = {
  category = "gui";
  platforms = ["darwin"];
  homebrew = { kind = "cask"; name = "iterm2"; };
  nixpkgs = "iterm2";
};
```

Darwin-only: `iterm2`, `rectangle`, `stats`, `utm`. Homebrew-only packages use `missingNixAttrs`.

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
