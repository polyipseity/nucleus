---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations, and documents shell-level enforcement for system-install-only build tools."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/Windows/**/*.yml, scripts/**, src/scripts/**, AGENTS.md, .agents/**/*.md, .envrc"
---

# Package Installation Scope Policy

## Core Principle

**All tools and libraries must be installed at user-level only.** System-wide installations are prohibited except where explicitly required for system infrastructure (e.g., nix-darwin system packages, WinGet DSC registry settings).

---

## Scope Classification

### User-Level (Permitted)

- **Binaries/CLI tools**: Installed to user-owned directories (`~/.cargo/bin`, `~/.bun/bin`, `~/.local/share/uv/tools/`, `%USERPROFILE%\.cargo\bin`, `%USERPROFILE%\.bun\bin`)
- **Library caches**: Centralized user caches (`~/.cargo/registry`, `~/.bun/store`, `~/.cache/uv`, `%USERPROFILE%\.bun\store`)
- **Project dependencies**: Stored locally per project (`.venv`, `node_modules`, `target/`, `Cargo.lock`)

### System-Level (Blocked)

- ❌ `/usr/bin`, `/usr/local/bin`, `C:\Windows\System32`, `Program Files`
- ❌ System-wide PATH modifications without user scoping
- ❌ `sudo` or admin invocations for package installation
- ❌ Package manager `-g` / `--global` flags for development tools (except where explicitly managed)

---

## Cross-Host Package Manager Hierarchy

| Scope                       | macOS (nix-darwin)                                    | NixOS                                      | Windows                                  |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------ | ---------------------------------------- |
| **System packages**         | `nixpkgs` via nix-darwin `environment.systemPackages` | `nixpkgs` via NixOS system config          | WinGet DSC (`system.dsc.yml`)            |
| **User-level CLI tools**    | `nixpkgs` via Home Manager `home.packages`            | `nixpkgs` via Home Manager `home.packages` | WinGet DSC (`user.dsc.yml`) + Scoop      |
| **Development tools**       | devShell (Nix flake)                                  | devShell (Nix flake)                       | devShell (Nix flake) OR managed fallback |
| **Managed global packages** | `bun install -g` (JS tools only)                      | `bun install -g` (JS tools only)           | `bun install -g` (JS tools only)         |
| **Prebuilt binaries**       | N/A                                                   | N/A                                        | `cargo-binstall`, Scoop                  |
| **Python tools**            | `uv tool install` (isolated venvs)                    | `uv tool install` (isolated venvs)         | `uv tool install` (isolated venvs)       |

**Preference order** (apply in sequence; use first available):

1. **Declarative (stateless)**: nix-darwin / NixOS / WinGet DSC — preferred for reproducibility
2. **Managed global**: `bun install -g`, `uv tool install` — for CLI-only tools with isolated environments
3. **Prebuilt**: `cargo-binstall`, Scoop — for binaries not in nixpkgs/WinGet
4. **Isolated project**: devShell, `.venv`, `node_modules` — for development

---

## System-Install-Only Tools

The following tools are installed globally (via nixpkgs / WinGet) for **system
package management only**. They are not available for general developer use in
interactive sessions:

| Tool             | Installed by                                        | Permitted system use                                                       |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| `bun`            | nixpkgs / `Oven-sh.Bun`                             | `bun add -g` for global Node/JS system packages                            |
| `cargo`          | all platforms: via `rustup` stable toolchain                               | `cargo-binstall` / `cargo install` for system Rust binary installs                              |
| `rustup`         | all platforms: `pkgs.rustup` (POSIX) / `Rustlang.Rustup` (Windows WinGet) | manages Rust toolchains; default = `none`; stable installed for cargo-binstall fallback         |
| `uv`             | nixpkgs / WinGet                                    | `uv tool install` for system-level Python tooling                          |
| `prek`           | nixpkgs                                             | system-wide Git hook manager binary (invoked by managed shell/apply hooks) |
| `python` / `pip` | **banned**                                          | no permitted system use; all Python via devShell or uv venv                |

Direct developer invocation of any of the above in an interactive shell session
must go through a **managed development environment** rather than the raw
system install.

---

## Shell-Level Enforcement

Each blocked tool is overridden as a **shell function** that intercepts the
command and prints a helpful error pointing to the devShell.

### POSIX (zsh) — `src/modules/shell.nix`

Functions for `bun`, `cargo`, `rustc`, `uv`, `python`, `python3`, `pip`,
`pip3` are defined in `programs.zsh.initContent`. They:

1. Check `$DIRENV_DIR` — set by direnv whenever an `.envrc` is active,
   including an **empty** `.envrc`.  An empty `.envrc` (or any non-flake
   `.envrc`) with a `rust-toolchain.toml` present is an **intentional**
   design: it signals a managed project directory and allows cargo to
   route through the rustup shim which reads the toolchain file.  The
   devShell (from a `use flake` `.envrc`) is the preferred path; empty
   `.envrc` is the lightweight alternative for projects that only need
   rustup-based toolchain selection without full Nix devShell overhead.
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

---

## devShell — Development Environment

For project-specific development, enter the project devShell. For repositories
without direnv/Nix metadata, nucleus also provisions a managed default shell
environment with the same baseline tools. The shared inventory is:

| Tool            | Purpose                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------- |
| `bun`           | JS/Node development                                                                             |
| `cargo`/`rustc` | Rust toolchain via **rust-overlay** (reads project `rust-toolchain.toml`; falls back to stable) |
| `prek`          | Git hook management during development                                                          |
| `uv`            | Python development                                                                              |

On all hosts, the devShell Rust toolchain is handled per-project. On POSIX,
`pkgs.rust-bin.fromRustupToolchainFile` (rust-overlay) assembles a Nix-patched
toolchain from the project's `rust-toolchain.toml` (or falls back to
`pkgs.rust-bin.stable.latest.default`) — distinct from the system `pkgs.rustup`
install so devShell toolchains are reproducible and version-pinned. On Windows,
rustup (`Rustlang.Rustup`) intercepts cargo invocations and reads
`rust-toolchain.toml` natively.

**Entering the devShell:**

- **POSIX — automatic (preferred):** direnv auto-loads the devShell when you
  enter a directory with an `.envrc` that contains `use flake`. No manual action
  required once direnv is configured.
- **POSIX — manual:** `nix develop` from the repo root (or any subdirectory).
- **POSIX — default fallback:** outside any active `.envrc`, the managed shell
  profile exposes the same bun/cargo/prek/rustc/uv inventory from the
  user-scoped fallback bundle at `$NUCLEUS_DEFAULT_DEV_BIN`.
- **Windows:** `nix develop` from WSL when a project provides it, or use the
  managed PowerShell profile fallback for repositories without direnv/Nix wiring.

---

## prek Hook Installation

prek Git hooks are installed by two complementary mechanisms:

| Mechanism                                            | Scope                                                     | Platform             |
| ---------------------------------------------------- | --------------------------------------------------------- | -------------------- |
| `src/scripts/apply.sh` `ensure_prek_hooks_installed` | nucleus repo, first apply                                 | POSIX                |
| zsh `_prek_hook_install_if_needed`                   | any `prek.toml` repo, on shell startup + directory change | POSIX                |
| PowerShell profile `Invoke-PrekHookInstallIfNeeded`  | any prek.toml repo, on directory entry                    | POSIX pwsh + Windows |

The POSIX zsh hook remains the canonical mechanism for non-direnv repository
entry (startup + directory change). PowerShell keeps prompt-hook parity for
POSIX pwsh and Windows.

---

## Adding or Changing Blocked Tools

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

---

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

---

## Tool Installation Patterns

### Python Tools (`uv`)

**Pattern**: Always use `uv tool install` for isolated, per-tool virtual environments.

```bash
# ✅ Correct: Installs to ~/.local/share/uv/tools/
uv tool install black

# ❌ Wrong: System-wide installation
pip install --system black
```

**Installation path**: `~/.local/share/uv/tools/` (added to `PATH` at user level)
**No system-wide Python installation**: All Python via devShell or isolated `uv` environments

---

### Rust Tools (`cargo`, `cargo-binstall`)

**Pattern**: Prefer devShell for development, `cargo-binstall` for prebuilt
binaries, `cargo install` as fallback.

```bash
# ✅ devShell (Nix flake): cargo build, cargo test
# ✅ outside devShell: cargo-binstall for prebuilt binaries
cargo binstall ripgrep
# Installs to ~/.cargo/bin
```

**Installation paths**: `~/.cargo/bin`, `%USERPROFILE%\.cargo\bin`
**System-wide rustc/cargo**: Blocked in interactive shells (see [Shell-Level Enforcement](#shell-level-enforcement))

---

### JavaScript Tools (`bun`)

**Pattern**: Only `bun install -g` for globally callable JS CLI tools (not dev dependencies).

```bash
# ✅ Correct: Installs to ~/.bun/bin (or %USERPROFILE%\.bun\bin on Windows)
bun install -g @tailwindlabs/tailwindcss

# ❌ Wrong: npm install -g (system-wide, unmanaged)
npm install -g @tailwindlabs/tailwindcss
```

**Managed via**:

- POSIX: `src/modules/agents.nix` — `installBunPackages` activation hook
- Windows: `src/hosts/Windows/modules/setup/Invoke-BunSetup.ps1`

**Installation path**: `~/.bun/bin`, `%USERPROFILE%\.bun\bin`

---

## Declarative vs. Imperative

### Declarative (Preferred)

**Nix packages** (POSIX):

```nix
# src/modules/core.nix or host config
home.packages = with pkgs; [
  ripgrep      # User-level CLI tool
  fd           # User-level CLI tool
];
```

**WinGet DSC** (Windows):

```yaml
# src/hosts/Windows/system.dsc.yml or user.dsc.yml
- name: Install ripgrep via WinGet
  resource: Microsoft.WinGet.DSC/WinGetPackage
  properties:
    id: BurntSushi.ripgrep.MSVC
```

### Imperative (Last Resort)

Only when declarative solutions don't exist:

- `bun install -g` for unpackaged JS tools
- `uv tool install` for Python CLI tools
- `cargo-binstall` for precompiled Rust binaries

**Always ensure**:

1. The tool installs to a **user-owned directory** (not system)
2. The installation is **idempotent** (safe to re-run)
3. The directory is in the user's `PATH`

---

## What Violates This Policy

| Pattern                                    | Issue                              | Fix                                         |
| ------------------------------------------ | ---------------------------------- | ------------------------------------------- |
| `sudo bun install -g …`                    | Admin escalation for user tool     | Remove `sudo`; use plain `bun install -g`   |
| `pip install --system …`                   | System-wide Python lib             | Use `uv tool install` or devShell           |
| `npm install -g …` (unmanaged)             | Untracked global package           | Use `bun install -g` with manifest tracking |
| Installing to `/usr/local/bin`             | System-level binary pollution      | Use user-level tool directories             |
| `cargo install` in `setup.sh`              | Imperative build-time tool install | Add to devShell or use `cargo-binstall`     |
| PowerShell `Install-Module -Scope Machine` | System-wide module installation    | Use `-Scope CurrentUser`                    |

---

## Testing & Validation

After adding or modifying packages:

1. **Verify installation paths**:

   ```bash
   # POSIX
   which <tool> && echo "Found at: $(which <tool>)"

   # Windows PowerShell
   (Get-Command <tool>).Source
   ```

2. **Confirm not in system directories**:

   ```bash
   # Should NOT match /usr/local, /usr/bin, C:\Windows\System32, Program Files
   which <tool> | grep -E "/usr/(local/)?bin|Program Files"  # Should return nothing
   ```

3. **Run bootstrap apply** and verify tool remains accessible:
   ```bash
   ./scripts/bootstrap.sh apply
   which <tool>  # Should still work
   ```

---

## Cross-Platform Examples

### Adding a new Rust CLI tool (e.g., `sd`)

```nix
# POSIX: src/modules/core.nix via home.packages
home.packages = with pkgs; [ sd ];
```

For Windows equivalents, see WinGet DSC patterns in
[Declarative vs. Imperative](#declarative-vs-imperative) above or use
`cargo-binstall` as documented in [Tool Installation Patterns](#tool-installation-patterns).

---

## References

- [winget-dsc.instructions.md](winget-dsc.instructions.md) — Windows package manager patterns (Scoop, cargo-binstall)
- [AGENTS.md - Package Management Strategy](../../../AGENTS.md#package-management-strategy) — nixpkgs vs. Homebrew selection on macOS
- [cross-host-feature-parity.instructions.md](cross-host-feature-parity.instructions.md) — Maintaining parity across hosts
- [nix.instructions.md](nix.instructions.md) — Shell module authoring rules (alias-vs-function precedence for blocked tools)
