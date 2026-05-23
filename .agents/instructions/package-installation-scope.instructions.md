---
description: "Use when adding, updating, or reviewing package installations across hosts (nixpkgs, WinGet, Scoop, cargo-binstall, bun). Enforces user-level-only for all tools and libraries, blocking system-wide installations."
name: "Package Installation Scope"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/windows/**/*.yml, scripts/**, src/scripts/**, AGENTS.md, .agents/**/*.md"
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

**POSIX (macOS, NixOS)**:

```bash
# ✅ Preferred in devShell (nix flake)
# Inside nix develop: cargo build, cargo test

# ✅ If outside devShell: cargo-binstall for prebuilt binaries
cargo binstall ripgrep
# Installs to ~/.cargo/bin
```

**Windows**:

```powershell
# ✅ Preferred: cargo-binstall for prebuilt binaries (no system-wide install)
cargo binstall ripgrep
# Installs to %USERPROFILE%\.cargo\bin

# ✅ Alternative: Use managed Scoop (user-level)
scoop install ripgrep
# Installs to %USERPROFILE%\scoop\shims
```

**Installation paths**: `~/.cargo/bin`, `%USERPROFILE%\.cargo\bin`
**System-wide rustc/cargo**: Blocked in interactive shells (see [build-tools-policy.instructions.md](build-tools-policy.instructions.md))

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
- Windows: `src/hosts/windows/modules/setup/Invoke-BunSetup.ps1`

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
# src/hosts/windows/system.dsc.yml or user.dsc.yml
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

### Example 1: Adding a new Rust CLI tool (e.g., `sd`)

**macOS (nix-darwin)**:

```nix
# src/modules/core.nix
home.packages = with pkgs; [
  sd  # User-level, installed via Nix
];
```

**NixOS**:

```nix
# src/hosts/nixos/default.nix
home.packages = with pkgs; [
  sd  # User-level, installed via Nix
];
```

**Windows**:

```yaml
# src/hosts/windows/system.dsc.yml
- name: Install sd via WinGet
  resource: Microsoft.WinGet.DSC/WinGetPackage
  properties:
    id: imr0ybhh.sd.msvc # Hypothetical ID
```

Or via `cargo-binstall` if WinGet unavailable:

```powershell
# In Invoke-CargoBinstallSetup.ps1
cargo binstall sd --root $env:USERPROFILE\.cargo
```

---

## References

- [build-tools-policy.instructions.md](build-tools-policy.instructions.md) — System-install-only tool blocking mechanism
- [winget-dsc.instructions.md](winget-dsc.instructions.md) — Windows package manager patterns (Scoop, cargo-binstall)
- [AGENTS.md - Package Management Strategy](../../../AGENTS.md#package-management-strategy) — nixpkgs vs. Homebrew selection on macOS
- [cross-host-feature-parity.instructions.md](cross-host-feature-parity.instructions.md) — Maintaining parity across hosts
