# nucleus Test Coverage Summary

## Overview

This document tracks test coverage across all **nucleus** platforms (macOS,
NixOS, Windows) and layers (Nix, PowerShell, Shell). The suite validates
configuration logic, module composition, package parity, and deployment
scripts.

---

## Test Suite Breakdown

### Nix Tests (Pure Evaluation Layer)

Located in `tests/src/`, run via `nix-instantiate --eval` in CI.

**Coverage**: Module options, import graphs, config composition, package parity,
option conflict detection, activation dependency ordering, SOPS structure
validation, and VS Code extension pruning. Run `ls tests/src/*.nix` for the
current authoritative list.

---

### Windows Tests (PowerShell + DSC Layer)

Located in `tests/src/hosts/Windows/`, organised by concern (`apps/`, `configuration/`,
`packages/`, `smoke/`, `system/`) and run via Pester locally on Windows.

#### ✅ **Windows Pester suites**

##### Package Installation Tests
- Cross-host CLI tooling: 7-Zip, zoxide, uv, Ruff, ty, ripgrep, direnv,
  GitHub CLI, prek, jq, fzf, bat, fd, ShellCheck, Typst
- Developer runtimes/editors: Git, PowerShell, VS Code stable + Insiders,
  Windows Terminal Preview, Neovim, Ollama, Bun, rustup, SOPS
- GUI applications: Blender, Discord Canary, Chrome Canary, QtPass,
  Obsidian, Telegram Desktop Beta

All tests validate cross-platform parity with nixpkgs/Homebrew equivalents.

##### Registry, Environment, and Policy Tests
- User-scoped DSC state: screen saver posture, managed wallpaper path,
  Explorer visibility/taskbar chrome settings, and managed environment vars
- System-scoped invariants: long paths, RDP enablement + NLA, firewall,
  TCP keepalive posture, lid-close power policy, and font substitutions
- App parity: QtPass registry values and Obsidian advanced-settings JSON
- Smoke coverage: Windows platform + PowerShell runtime validation

**Windows Test Totals**: multiple focused suites covering package parity,
user configuration, system invariants, app-specific parity, and smoke checks

---

### Shell Script Tests

Located in `tests/scripts/script-validation-tests.sh`, run via bash in CI.

#### ✅ **script-validation-tests.sh** (8 test categories)

1. **Bash Syntax Validation**: Parse-only checks on all `.sh` files
2. **Shebang Verification**: All scripts start with `#!/bin/bash` or `#!/bin/sh`
3. **Executable Bit Validation**: `.sh` files tracked with `100755` permission
4. **Dependency Availability**: Check for nix, bash, PowerShell availability
5. **Error Handling**: Verify scripts don't use bare `|| true` without comments
6. **Documentation**: Measure comment coverage and usage documentation
7. **Dangerous Patterns**: Detect unquoted variables, unsafe `rm -rf`, unescaped globs
8. **Shell Portability**: Validate scripts work on macOS (zsh/bash) and Linux

**Scripts Tested**: `bootstrap.sh`, `apply.sh`, `health-check.sh`, `update.sh`, `check.sh`

**Shell Test Totals**: **8 validation categories** covering all deployment scripts

#### ✅ **Consolidated check scripts**

- `scripts/check.sh` (POSIX): Runs all 5 check categories (deadnix, shellcheck, PowerShell lint, Packer validation, script validation tests)
- `scripts/check.ps1` (Windows): Runs Windows-compatible checks (PowerShell lint, Packer validation)
- `scripts/test.sh` / `scripts/test.ps1`: Separate test suite runner (Nix eval on POSIX, placeholder on Windows)
- Both check scripts delegate to existing individual checkers; no logic duplication
- Path-scoped mode skips whole-repo checks when arguments provided

---

## CI Integration

### .github/workflows/ci.yml

All tests are automatically run on every commit:

1. **Nix Parse** (`nix flake check`): Verify all `.nix` files parse
2. **Consolidated POSIX Checks** (`nix run ./src#check`): Runs deadnix, shellcheck, PowerShell lint, Packer validation, and script validation tests in one step (macOS/Linux)
3. **Repository test suite (POSIX)** (`nix run ./src#test`): Evaluates all `tests/src/*.nix` test files (macOS/Linux)
4. **Consolidated Windows Checks** (`pwsh -File scripts/check.ps1`): Runs PowerShell lint and Packer validation (Windows)
5. **Repository test suite (Windows)** (`pwsh -File scripts/test.ps1`): Placeholder for future Windows test support

---

## Coverage by Platform

### macOS (Darwin)

| Layer | Coverage | Status |
|-------|----------|--------|
| Nix configuration | ✅ Module composition, options | Full |
| Package selection | ✅ Homebrew/nixpkgs parity | Full |
| Activation hooks | ❌ Manual testing only | Partial |
| Security policies | ✅ Home Manager validation | Full |

### NixOS

| Layer | Coverage | Status |
|-------|----------|--------|
| Nix configuration | ✅ Module composition, options | Full |
| Package selection | ✅ nixpkgs parity | Full |
| Activation hooks | ❌ Manual testing only | Partial |
| Security policies | ✅ System-wide validation | Full |

### Windows

| Layer | Coverage | Status |
|-------|----------|--------|
| WinGet DSC | ✅ Package installation, registry | Full |
| PowerShell modules | ✅ Syntax validation | Partial |
| Activation hooks | ❌ Manual testing only | Partial |
| Security policies | ✅ Registry invariants | Full |

---

## Untested Areas

Activation hooks, secret decryption, and deployment validation require live
systems and are not unit-testable in CI. Mock tests cover secret structure.

---

## Test Execution

### Local Testing

**Run all Nix tests:**
```bash
nix flake check src/
nix-instantiate --eval tests/src/*.nix
```

**Run Windows Pester tests:**
```powershell
pwsh -Command "Invoke-Pester tests/src/hosts/Windows/"
```

**Run shell script validation:**
```bash
bash tests/scripts/script-validation-tests.sh
```

### CI Testing

Tests are automatically run via `.github/workflows/ci.yml` on every commit to `main`.

To run locally:
```bash
act push --job test  # Requires 'act' (https://github.com/nektos/act)
```

---

## Test Maintenance Guidelines

1. **Add tests for new modules**: Every `.nix` file in `src/modules/` should have corresponding tests in `tests/src/module-imports-tests.nix`
2. **Update parity tests**: When adding a new package, add it to `package-parity-tests.nix` across all platforms
3. **Validate security policies**: All invariants in `AGENTS.md` must have corresponding tests
4. **Document untested areas**: Update this file when adding test coverage

---

**Last Updated**: Continuous (update this file whenever suite structure changes)
**Nix Suite Status**: See `ls tests/src/*.nix` for current list
**Windows Suite Status**: hierarchical Pester suites under `tests/src/hosts/Windows/**`
**Shell Suite Status**: script validation checks in `tests/scripts/`
