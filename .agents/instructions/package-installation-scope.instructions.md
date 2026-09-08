---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

## Core principle

All tools and libraries at user-level only. System-wide prohibited except where required for system infrastructure (nix-darwin system packages, WinGet DSC registry settings).

## Cross-host package manager hierarchy

| Scope | macOS (nix-darwin) | NixOS | Windows |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------- |
| **System packages** | `nixpkgs` via nix-darwin `environment.systemPackages` | `nixpkgs` via NixOS system config | WinGet DSC (`system-packages.dsc.yml`) |
| **User-level CLI tools** | `nixpkgs` via Home Manager `home.packages` | `nixpkgs` via Home Manager `home.packages` | WinGet DSC (`user.dsc.yml`, `user-env.dsc.yml`) + Scoop |
| **Managed global packages** | `bun install -g` (JS only) | `bun install -g` (JS only) | `bun install -g` (JS only) |
| **Prebuilt binaries** | N/A | N/A | `cargo-binstall`, Scoop |
| **Python tools** | `uv tool install` (isolated venvs) | `uv tool install` (isolated venvs) | `uv tool install` (isolated venvs) |

## System-install-only tools

Installed globally for system package management only — not available for interactive dev use:

| Tool | Installed by | Permitted system use |
| ----------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `bun` | nixpkgs / `Oven-sh.Bun` | `bun add -g` for global JS system packages |
| `cargo` | via `rustup` stable toolchain | `cargo-binstall` / `cargo install` for system Rust binary installs |
| `rustup` | `pkgs.rustup` (POSIX) / `Rustlang.Rustup` (Windows) | manages toolchains; default `none`; stable for cargo-binstall |
| `uv` | nixpkgs / WinGet | `uv tool install` for system Python tooling |
| `prek` | nixpkgs | system-wide Git hook manager |
| `python` / `pip` | **banned** | all Python via devShell or uv venv |
| `npm` / `npx` / `node` / `corepack` | **banned** | all JS via bun |

Direct invocation must go through a managed dev environment, not the raw system install.

## Shell-level enforcement

Each blocked tool is overridden as a shell function intercepting the command with an error pointing to the devShell.

- **POSIX (zsh)** — `src/scripts/shell/init.zsh`: functions in `programs.zsh.initContent`. Flow: check `$DIRENV_DIR` → devShell binary → alternative tool bundle → error. Educational blocks (`npm`/`npx`/`node`/`corepack`, `pip`/`pip3`, `python`/`python3`) print a ban message directly.
- **PowerShell** — `src/scripts/shell/profile.ps1`: shared profile consumed by `src/modules/pwsh.nix` (POSIX, eval-time) and `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` (Windows, runtime). Same flow via `$env:DIRENV_DIR`.

PATH wiring via `home.sessionPath` (→ `~/.zshenv`), not `initContent` guards — survives direnv deactivation.

## Development environment (devShell)

For project-specific work, enter the devShell. For repos without direnv/Nix, a managed default shell provides: `bun`, `cargo`/`rustc`, `prek`, `uv`.

- **POSIX automatic (preferred):** direnv with `.envrc` containing `use flake`.
- **POSIX manual:** `nix develop` from repo root.
- **POSIX default alternative:** managed shell profile outside any `.envrc`.
- **Windows:** `nix develop` via WSL, or managed PowerShell profile.

POSIX: `pkgs.rust-bin.fromRustupToolchainFile` (rust-overlay) assembles the toolchain from `rust-toolchain.toml` — distinct from system `pkgs.rustup`. Windows: rustup reads `rust-toolchain.toml` natively.

## Adding/changing blocked tools

1. Add blocking function to `src/modules/shell.nix` (`initContent`), following existing `bun`/`cargo`/`rustc`/`uv` pattern.
2. Add equivalent PowerShell function to `src/scripts/shell/profile.ps1`.
3. Update this instruction file.
4. If also a devShell tool, add to `devShells.default` in `src/flake.nix` (alphabetically sorted).

## Invariants

- `DIRENV_DIR` pass-through required in every blocking function.
- Alternative managed environment exposes same baseline as `devShells.default`: `bun`, `cargo`, `prek`, `rustc`, `uv`.
- Not blocked: `cargo-binstall`, `cargo-cache` (permitted system-package-management Rust invocations), `rustup` (toolchain manager), `ruff`, `ty` (linters for editor integration).

## Tool installation patterns

- **Python:** `uv tool install` for isolated per-tool venvs. Never `pip install --system`.
- **Rust:** devShell for development, `cargo-binstall` for prebuilt, `cargo install` as fallback. Installs to `~/.cargo/bin`.
- **JavaScript:** `bun install -g` for global CLI tools only. Managed via `src/modules/agents.nix` (POSIX) or `Invoke-BunSetup.ps1` (Windows). Never `npm install -g`.

## Managed package classification

Every cross-platform package declared once in `src/modules/core.nix`'s `managedPackages` with metadata (nixpkgs attr, Homebrew, WinGet). `category` selects the backend:

- `"cli"` → nixpkgs
- `"gui"` → Homebrew (cask preferred) on macOS; nixpkgs on NixOS

Ship GUI component? Classify as `"gui"` even if it also has CLI-only tools.

### Platform restrictions

Platform-specific packages declare `platforms` in `managedPackages`:

```nix
iterm2 = {
  category = "gui";
  platforms = ["darwin"];
  homebrew = { kind = "cask"; name = "iterm2"; };
  nixpkgs = "iterm2";
};
```

Known darwin-only: `iterm2`, `rectangle`, `stats`, `utm`. Packages in Homebrew but not nixpkgs use `missingNixAttrs` in `core.nix`.

### Adding a managed package

1. Add to `managedPackages` in `src/modules/core.nix` (alphabetical).
2. Add `platforms = ["darwin"]` if macOS-only.
3. Choose category.
4. Remove duplicates from `src/hosts/NixOS/desktop.nix` if needed.

## Violations

| Pattern | Issue | Fix |
| ------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| `sudo bun install -g ...` | Admin escalation | Remove `sudo` |
| `pip install --system ...` | System-wide Python | Use `uv tool install` or devShell |
| `npm install -g` / `npx ...` / `node` (unmanaged) | Untracked JS | Use `bun install -g` / `bun x` |
| Installing to `/usr/local/bin` | Binary pollution | Use user-level tool directories |
| `cargo install` in `setup.sh` | Imperative build-time install | Add to devShell or use `cargo-binstall` |
| `Install-Module -Scope Machine` | System-wide module | Use `-Scope CurrentUser` |
