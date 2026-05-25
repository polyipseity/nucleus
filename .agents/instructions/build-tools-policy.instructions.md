---
description: "Use when adding or editing system packages, devShells, shell profiles, or build tool references. Covers the system-install-only policy for bun/cargo/uv/prek (and Windows-only rustup), the shell blocking mechanism, and devShell-first development guidance."
name: "Build Tools Policy"
applyTo: "src/modules/core.nix, src/modules/shell.nix, src/modules/pwsh.nix, src/flake.nix, src/hosts/Windows/modules/user/Sync-ShellProfile.ps1, .envrc"
---

# Build Tools Policy

## System-install-only tools

The following tools are installed globally (via nixpkgs / WinGet) for **system
package management only**. They are not available for general developer use in
interactive sessions:

| Tool             | Installed by                                        | Permitted system use                                                       |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| `bun`            | nixpkgs / `Oven-sh.Bun`                             | `bun add -g` for global Node/JS system packages                            |
| `cargo`          | POSIX: `nixpkgs pkgs.cargo` / Windows: via `rustup` | `cargo-binstall` / `cargo install` for system Rust binary installs         |
| `rustup`         | Windows only: `Rust.Rustup` (WinGet)                | manages per-project toolchains via `rust-toolchain.toml`; default = `none` |
| `uv`             | nixpkgs / WinGet                                    | `uv tool install` for system-level Python tooling                          |
| `prek`           | nixpkgs                                             | system-wide Git hook manager binary (invoked by managed shell/apply hooks) |
| `python` / `pip` | **banned**                                          | no permitted system use; all Python via devShell or uv venv                |

Direct developer invocation of any of the above in an interactive shell session
must go through a **managed development environment** rather than the raw
system install.

## Shell-level enforcement

Each blocked tool is overridden as a **shell function** that intercepts the
command and prints a helpful error pointing to the devShell.

### POSIX (zsh) — `src/modules/shell.nix`

Functions for `bun`, `cargo`, `rustc`, `uv`, `python`, `python3`, `pip`,
`pip3` are defined in `programs.zsh.initContent`. They:

1. Check `$DIRENV_DIR` — set by direnv whenever an `.envrc` is active.
2. If set, invoke `command <tool>` to bypass the function and reach the
   devShell-scoped binary at the front of `PATH`.
3. Otherwise, invoke the managed fallback toolchain published via
   `$NUCLEUS_DEFAULT_DEV_BIN`. On POSIX this path points at a dedicated
   Nix-built bundle containing the default development tools.
4. If neither context is available, print a `shell: …` banner to stderr and
   return 1.

**User-scope bin dir PATH wiring**: `~/.bun/bin`, `~/.cargo/bin`, and
`~/.local/bin` are declared via `home.sessionPath`, **not** via `initContent`
PATH guards. `home.sessionPath` writes to `~/.zshenv` (via the Home Manager
session-vars mechanism) which is sourced before `~/.zshrc` (where the direnv
hook lives). This ensures these directories are always part of the "original"
PATH state that direnv captures and restores, even if the directories did not
exist at the time the shell first started. Do **not** revert to `initContent`
guarded `export PATH=...` lines — they are fragile under direnv because they
only run at shell startup and are lost after a direnv deactivation if the
directory was created later in the same session.

### POSIX (pwsh) — `src/modules/pwsh.nix`

Equivalent PowerShell functions in `profileContent`. Pass-through first uses
`$env:DIRENV_DIR`, then the managed fallback toolchain published via
`$env:NUCLEUS_DEFAULT_DEV_BIN`.

### Windows (PowerShell) — `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1`

Same functions emitted into the managed block. Pass-through uses
`$env:DIRENV_DIR` when present and otherwise the managed default shell
environment flag (`$env:NUCLEUS_DEFAULT_DEV_ENV`). Windows currently reuses the
managed user PATH entries instead of a second Nix-backed fallback root because
the WinGet/PowerShell workflow has no nix-direnv-equivalent store path today.

**User-scope bin dir PATH wiring**: `~\.bun\bin` and `~\.cargo\bin` are
prepended **unconditionally** (no `Test-Path` guard) at the top of the managed
block, before the direnv hook. This mirrors the POSIX `home.sessionPath`
approach: the entries are always present in the environment direnv saves and
restores, so they survive activation/deactivation cycles even when the
directories were created after the current session started. Do **not** add
`Test-Path` guards back — they break this contract.

## devShell — development environment

For project-specific development, enter the project devShell. For repositories
without direnv/Nix metadata, nucleus also provisions a managed default shell
environment with the same baseline tools. The shared inventory is:

| Tool            | Purpose                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------- |
| `bun`           | JS/Node development                                                                             |
| `cargo`/`rustc` | Rust toolchain via **rust-overlay** (reads project `rust-toolchain.toml`; falls back to stable) |
| `prek`          | Git hook management during development                                                          |
| `uv`            | Python development                                                                              |

On POSIX hosts the devShell Rust toolchain is provided by
`pkgs.rust-bin.fromRustupToolchainFile` (rust-overlay) when a
`rust-toolchain.toml` is present in the project root, or
`pkgs.rust-bin.stable.latest.default` otherwise — no system-level rustup
required. On Windows, rustup (installed via `Rust.Rustup`) intercepts cargo
invocations and reads `rust-toolchain.toml` natively.

### Entering the devShell

**POSIX — automatic (preferred):** direnv auto-loads the devShell when you
enter a directory with an `.envrc` that contains `use flake`. No manual action
required once direnv is configured.

**POSIX — manual:** `nix develop` from the repo root (or any subdirectory).

**POSIX — default fallback:** outside any active `.envrc`, the managed shell
profile exposes the same bun/cargo/prek/rustc/uv inventory from the
user-scoped fallback bundle at `$NUCLEUS_DEFAULT_DEV_BIN`.

**Windows:** `nix develop` from WSL when a project provides it, or use the
managed PowerShell profile fallback for repositories without direnv/Nix wiring.

## prek hook installation

prek Git hooks are installed by two complementary mechanisms:

| Mechanism                                            | Scope                                                     | Platform             |
| ---------------------------------------------------- | --------------------------------------------------------- | -------------------- |
| `src/scripts/apply.sh` `ensure_prek_hooks_installed` | nucleus repo, first apply                                 | POSIX                |
| zsh `_prek_hook_install_if_needed`                   | any `prek.toml` repo, on shell startup + directory change | POSIX                |
| PowerShell profile `Invoke-PrekHookInstallIfNeeded`  | any prek.toml repo, on directory entry                    | POSIX pwsh + Windows |

The POSIX zsh hook remains the canonical mechanism for non-direnv repository
entry (startup + directory change). PowerShell keeps prompt-hook parity for
POSIX pwsh and Windows.

## Adding or changing blocked tools

1. Add the blocking shell function to `src/modules/shell.nix` (`initContent`),
   following the existing `bun`/`cargo`/`rustc`/`uv` pattern.
2. Add the equivalent PowerShell function to `src/modules/pwsh.nix`
   (`profileContent`) for POSIX PowerShell parity.
3. Add the same function to the `$managedBlock` array in
   `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` for Windows parity.
4. Update this instruction file and the `core.nix` policy comment table.
5. If the tool is also a devShell tool (i.e., developers need it for project
   work), add it to both `devShells.default` entries in `src/flake.nix`
   (alphabetically sorted in the `packages` list).

## Invariants

- The `DIRENV_DIR` pass-through must be present in every blocking function.
  Omitting it would prevent the tool from working inside nix devShells.
- The managed fallback environment must expose the same baseline inventory as
  `devShells.default`: `bun`, `cargo`, `prek`, `rustc`, and `uv`.
- `cargo-binstall` and `cargo-cache` are **not** blocked — they are the
  permitted system-package-management invocations of the Rust toolchain.
- `rustup` is **not** blocked — it is the toolchain manager and must remain
  accessible for toolchain lifecycle management.
- `ruff` and `ty` are **not** blocked — they are linting/formatting tools that
  must be globally accessible for editor integrations (e.g., VS Code extensions).
