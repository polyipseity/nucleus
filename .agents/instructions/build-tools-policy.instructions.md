---
description: "Use when adding or editing system packages, devShells, shell profiles, or build tool references. Covers the system-install-only policy for bun/cargo/rustc/uv/prek, the shell blocking mechanism, and devShell-first development guidance."
name: "Build Tools Policy"
applyTo: "src/modules/core.nix, src/modules/shell.nix, src/modules/pwsh.nix, src/flake.nix, src/hosts/windows/modules/Sync-ShellProfile.ps1, .envrc"
---

# Build Tools Policy

## System-install-only tools

The following tools are installed globally (via nixpkgs / WinGet) for **system
package management only**. They are not available for general developer use in
interactive sessions:

| Tool | Installed by | Permitted system use |
|---|---|---|
| `bun` | nixpkgs / `Oven-sh.Bun` | `bun add -g` for global Node/JS system packages |
| `cargo` | nixpkgs `rustup` | used internally by `cargo-binstall` for system Rust binary installs |
| `rustc` | nixpkgs `rustup` | compilation during `cargo-binstall` runs |
| `uv` | nixpkgs / WinGet | `uv tool install` for system-level Python tooling |
| `prek` | nixpkgs | system-wide Git hook manager binary (invoked by `apply.sh` / `.envrc`) |
| `python` / `pip` | **banned** | no permitted system use; all Python via devShell or uv venv |

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

### POSIX (pwsh) — `src/modules/pwsh.nix`

Equivalent PowerShell functions in `profileContent`. Pass-through first uses
`$env:DIRENV_DIR`, then the managed fallback toolchain published via
`$env:NUCLEUS_DEFAULT_DEV_BIN`.

### Windows (PowerShell) — `src/hosts/windows/modules/Sync-ShellProfile.ps1`

Same functions emitted into the managed block. Pass-through uses
`$env:DIRENV_DIR` when present and otherwise the managed default shell
environment flag (`$env:NUCLEUS_DEFAULT_DEV_ENV`). Windows currently reuses the
managed user PATH entries instead of a second Nix-backed fallback root because
the WinGet/PowerShell workflow has no nix-direnv-equivalent store path today.

## devShell — development environment

For project-specific development, enter the project devShell. For repositories
without direnv/Nix metadata, nucleus also provisions a managed default shell
environment with the same baseline tools. The shared inventory is:

| Tool | Purpose |
|---|---|
| `bun` | JS/Node development |
| `cargo` | Rust build and test |
| `prek` | Git hook management during development |
| `rustc` | Rust compilation |
| `uv` | Python development |

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

| Mechanism | Scope | Platform |
|---|---|---|
| `src/scripts/apply.sh` `ensure_prek_hooks_installed` | nucleus repo, first apply | POSIX |
| `.envrc` `prek install` block | nucleus repo, every direnv entry | POSIX |
| PowerShell profile `Invoke-PrekHookInstallIfNeeded` | any prek.toml repo, on directory entry | POSIX pwsh + Windows |

The zsh chpwd hook was **removed** in favour of the direnv-based approach.
WHY: direnv fires on directory entry and is already part of the managed shell
setup; a separate zsh hook was redundant and added complexity. The PowerShell
prompt hook remains as the Windows parity mechanism.

## Adding or changing blocked tools

1. Add the blocking shell function to `src/modules/shell.nix` (`initContent`),
   following the existing `bun`/`cargo`/`rustc`/`uv` pattern.
2. Add the equivalent PowerShell function to `src/modules/pwsh.nix`
   (`profileContent`) for POSIX PowerShell parity.
3. Add the same function to the `$managedBlock` array in
   `src/hosts/windows/modules/Sync-ShellProfile.ps1` for Windows parity.
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
