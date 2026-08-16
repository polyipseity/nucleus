---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**"
---

# Package installation scope

## Core principle

All tools and libraries must be installed at user-level only. System-wide installations are prohibited except where explicitly required for system infrastructure (e.g., nix-darwin system packages, WinGet DSC registry settings).

## Cross-host package manager hierarchy

| Scope                       | macOS (nix-darwin)                                    | NixOS                                      | Windows                                                 |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------- |
| **System packages**         | `nixpkgs` via nix-darwin `environment.systemPackages` | `nixpkgs` via NixOS system config          | WinGet DSC (`system-packages.dsc.yml`)                  |
| **User-level CLI tools**    | `nixpkgs` via Home Manager `home.packages`            | `nixpkgs` via Home Manager `home.packages` | WinGet DSC (`user.dsc.yml`, `user-env.dsc.yml`) + Scoop |
| **Managed global packages** | `bun install -g` (JS tools only)                      | `bun install -g` (JS tools only)           | `bun install -g` (JS tools only)                        |
| **Prebuilt binaries**       | N/A                                                   | N/A                                        | `cargo-binstall`, Scoop                                 |
| **Python tools**            | `uv tool install` (isolated venvs)                    | `uv tool install` (isolated venvs)         | `uv tool install` (isolated venvs)                      |

## System-install-only tools

The following tools are installed globally (via nixpkgs / WinGet) for system package management only. They are not available for general developer use in interactive sessions:

| Tool                                | Installed by                                                       | Permitted system use                                                                    |
| ----------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `bun`                               | nixpkgs / `Oven-sh.Bun`                                            | `bun add -g` for global JS system packages                                              |
| `cargo`                             | all platforms: via `rustup` stable toolchain                       | `cargo-binstall` / `cargo install` for system Rust binary installs                      |
| `rustup`                            | all platforms: `pkgs.rustup` (POSIX) / `Rustlang.Rustup` (Windows) | manages Rust toolchains; default = `none`; stable installed for cargo-binstall fallback |
| `uv`                                | nixpkgs / WinGet                                                   | `uv tool install` for system-level Python tooling                                       |
| `prek`                              | nixpkgs                                                            | system-wide Git hook manager binary (invoked by managed shell/apply hooks)              |
| `python` / `pip`                    | **banned**                                                         | no permitted system use; all Python via devShell or uv venv                             |
| `npm` / `npx` / `node` / `corepack` | **banned**                                                         | no permitted system use; all JS via bun                                                 |

Direct developer invocation of any of the above in an interactive shell session must go through a managed development environment rather than the raw system install.

## Shell-level enforcement

Each blocked tool is overridden as a shell function that intercepts the command and prints a helpful error pointing to the devShell.

- **POSIX (zsh)** — `src/scripts/shell/init.zsh`: functions for `bun`, `cargo`, `rustc`, `uv`, `python`, `python3`, `pip`, `pip3`, `npm`, `npx`, `node`, `corepack` in `programs.zsh.initContent`. Flow: check `$DIRENV_DIR` → invoke devShell-scoped binary → check fallback tool bundle path → error. Pure educational blocks (`npm`/`npx`/`node`/`corepack`, `pip`/`pip3`, `python`/`python3`) skip the pass-through flow and print a ban message directly.
- **PowerShell (POSIX and Windows)** — `src/scripts/shell/profile.ps1`: the single shared shell-parity profile. POSIX gets it embedded by `src/modules/pwsh.nix` at Nix eval time; Windows gets it written into the managed profile block by `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` at runtime. Same flow via `$env:DIRENV_DIR` then the fallback tool bundle path.

User-scope bin dir PATH wiring is declared via `home.sessionPath` (→ `~/.zshenv`), not `initContent` PATH guards. This ensures directories survive direnv deactivation.

## Development environment (devShell)

For project-specific development, enter the project devShell. For repositories without direnv/Nix metadata, nucleus also provisions a managed default shell environment with the same baseline tools: `bun`, `cargo`/`rustc`, `prek`, `uv`.

- **POSIX — automatic (preferred):** direnv auto-loads the devShell when a directory has an `.envrc` with `use flake`.
- **POSIX — manual:** `nix develop` from the repo root.
- **POSIX — default fallback:** outside any active `.envrc`, the managed shell profile exposes the same inventory from the fallback tool bundle.
- **Windows:** `nix develop` from WSL when available, or the managed PowerShell profile fallback.

On POSIX, `pkgs.rust-bin.fromRustupToolchainFile` (rust-overlay) assembles a Nix-patched toolchain from the project's `rust-toolchain.toml` (or falls back to `pkgs.rust-bin.stable.latest.default`) — distinct from the system `pkgs.rustup` install so devShell toolchains are reproducible and version-pinned. On Windows, rustup (`Rustlang.Rustup`) intercepts cargo invocations and reads `rust-toolchain.toml` natively.

## Adding or changing blocked tools

1. Add the blocking shell function to `src/modules/shell.nix` (`initContent`), following the existing `bun`/`cargo`/`rustc`/`uv` pattern.
2. Add the equivalent PowerShell function to `src/scripts/shell/profile.ps1` — the single shared shell-parity profile consumed by both `src/modules/pwsh.nix` (POSIX, embedded at eval time) and `src/platforms/Windows/modules/user/Sync-ShellProfile.ps1` (Windows, managed block).
4. Update this instruction file.
5. If the tool is also a devShell tool, add it to `devShells.default` in `src/flake.nix` (alphabetically sorted in the `packages` list).

## Invariants

- The `DIRENV_DIR` pass-through must be present in every blocking function. Omitting it would prevent the tool from working inside nix devShells.
- The managed fallback environment must expose the same baseline inventory as `devShells.default`: `bun`, `cargo`, `prek`, `rustc`, and `uv`.
- `cargo-binstall` and `cargo-cache` are not blocked — they are the permitted system-package-management invocations of the Rust toolchain.
- `rustup` is not blocked — it is the toolchain manager and must remain accessible for toolchain lifecycle management.
- `ruff` and `ty` are not blocked — they are linting/formatting tools that must be globally accessible for editor integrations (e.g., VS Code extensions).

## Tool installation patterns

- **Python tools**: Always use `uv tool install` for isolated, per-tool virtual environments. Never `pip install --system`.
- **Rust tools**: Prefer devShell for development, `cargo-binstall` for prebuilt binaries, `cargo install` as fallback. Installs to `~/.cargo/bin`.
- **JavaScript tools**: Only `bun install -g` for globally callable JS CLI tools (not dev dependencies). Managed via `src/modules/agents.nix` (POSIX) or `src/platforms/Windows/modules/setup/Invoke-BunSetup.ps1` (Windows). Never `npm install -g`.

## Overlapping package classification

Packages available in both nixpkgs and Homebrew use a `category` field in `src/modules/core.nix`'s `overlappingPackages` to decide the install backend. This mechanism works cross-platform:

- **macOS**: routes to either nixpkgs or Homebrew based on `category` and backend policy.
- **NixOS**: all platform-compatible packages go through nixpkgs unconditionally.

Category rules:

- `"cli"` → nixpkgs
- `"gui"` → Homebrew (cask preferred, formula fallback) on macOS; nixpkgs on NixOS

If a package ships any GUI component (graphical binary, UI frontend, background daemon with a UI), classify it as `"gui"` even if it also provides CLI-only tools.

### Platform restrictions

Packages that only exist on a specific platform must declare a `platforms` field in their `overlappingPackages` entry:

```nix
iterm2 = {
  category = "gui";
  platforms = ["darwin"];  # only available on macOS
  homebrew = { kind = "cask"; name = "iterm2"; };
  nixpkgsAttr = "iterm2";
};
```

Known darwin-only packages: `iterm2`, `rectangle`, `stats`, `utm`.

For packages that exist in Homebrew but not in nixpkgs, use `missingNixAttrs` in `core.nix` to keep them declared in the same central location.

### Adding a new overlapping package

1. Add an entry to `overlappingPackages` in `src/modules/core.nix`, alphabetically sorted.
2. If the package only exists on macOS, add `platforms = ["darwin"]`.
3. Choose the appropriate `category`.
4. Remove any duplicate declaration from `src/hosts/NixOS/desktop.nix` if needed.

## What violates this policy

| Pattern                                           | Issue                         | Fix                                         |
| ------------------------------------------------- | ----------------------------- | ------------------------------------------- |
| `sudo bun install -g ...`                         | Admin escalation              | Remove `sudo`; use plain `bun install -g`   |
| `pip install --system ...`                        | System-wide Python            | Use `uv tool install` or devShell           |
| `npm install -g` / `npx ...` / `node` (unmanaged) | Untracked JS ecosystem usage  | Use `bun install -g` / `bun x`              |
| `npm install -g ...` (unmanaged)                  | Untracked global package      | Use `bun install -g` with manifest tracking |
| Installing to `/usr/local/bin`                    | Binary pollution              | Use user-level tool directories             |
| `cargo install` in `setup.sh`                     | Imperative build-time install | Add to devShell or use `cargo-binstall`     |
| `Install-Module -Scope Machine`                   | System-wide module            | Use `-Scope CurrentUser`                    |
