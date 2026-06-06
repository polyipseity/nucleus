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

**Coverage**: 31 test files covering module options, import graphs, config
composition, package parity, option conflict detection, activation dependency
ordering, SOPS structure validation, and VS Code extension pruning. Run
`ls tests/src/*.nix` for the current authoritative list.

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

#### ✅ **Consolidated check scripts** (NEW)

- `scripts/check.sh` (POSIX): Runs all 6 check categories (Nix tests, deadnix, shellcheck, PowerShell lint, Packer validation, script validation tests)
- `scripts/check.ps1` (Windows): Runs Windows-compatible checks (PowerShell lint, Packer validation)
- Both delegate to existing individual checkers; no logic duplication
- Path-scoped mode skips whole-repo checks when arguments provided

---

## CI Integration

### .github/workflows/ci.yml

All tests are automatically run on every commit:

1. **Nix Parse** (`nix flake check`): Verify all `.nix` files parse
2. **Consolidated POSIX Checks** (`nix run ./src#check`): Runs Nix tests, deadnix, shellcheck, PowerShell lint, Packer validation, and script validation tests in one step (macOS/Linux)
3. **Consolidated Windows Checks** (`pwsh -File scripts/check.ps1`): Runs PowerShell lint and Packer validation (Windows)

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

## Untested Areas (Known Gaps) → Gap Addressing Status

### ✅ HIGH PRIORITY (NOW ADDRESSED)

1. **✅ Backend Package Selection Logic** (FIXED)
   - `resolveBackend` decision tree (3 resolution layers)
   - Package categorization by category
   - Platform detection edge cases
   - **Tests**: `core-tests.nix` (10 tests total, 6 new backend tests)
   - **Coverage**: All branches of override→policy→global fallback

2. **✅ Configuration Conflict Detection** (FIXED)
   - Module option merge safety via mkIf/mkDefault
   - Security policy enforcement
   - Type consistency across modules
   - **Tests**: `option-conflict-tests.nix` (11 new tests)
   - **Coverage**: Bidirectional merge patterns, option precedence

3. **✅ Cross-Module Dependency Verification** (FIXED)
   - Activation hook ordering (Home Manager DAG)
   - Dev repo provisioning sequence
   - Secret materialization timing
   - **Tests**: `activation-deps-tests.nix` (12 new tests)
   - **Coverage**: 12 activation dependency invariants

4. **✅ Secret Handling Configuration** (FIXED)
   - SOPS key structure validation
   - Age key format correctness
   - Secret file mappings
   - **Tests**: `sops-mock-tests.nix` (15 new tests, no encryption required)
   - **Coverage**: Structure validation without live secrets

### ⚠️ ARCHITECTURAL GAPS (Cannot test in CI without live systems)

The following gaps are intentionally NOT unit-tested because they require
live system state, actual deployments, or ephemeral VMs:

1. **Live Activation Hook Execution**
   - Home Manager activation on macOS/NixOS
   - darwin-rebuild apply and nixos-rebuild switch
   - Windows DSC apply
   - **Why not tested**: Requires actual system changes, suitable for integration/e2e testing
   - **Alternative**: Manual validation on ephemeral VMs

2. **Real Secret Decryption**
   - SOPS age key decryption with real encrypted files
   - Git SSH key materialization
   - GPG key import from encrypted backup
   - **Why not tested**: Requires valid encrypted files + keys (security concern)
   - **Alternative**: Mock tests (now in place via sops-mock-tests.nix)

3. **Deployment Validation**
   - Full configuration evaluation on target systems
   - Package installation success verification
   - Security policy enforcement on live systems
   - **Why not tested**: Requires target machine state
   - **Alternative**: Integration tests on ephemeral VMs

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

## Future Roadmap

### Phase 2: Integration Testing
- [ ] Add Nix evaluation tests that validate module outputs without system changes
- [ ] Mock SOPS for secret decryption tests
- [ ] Add Pester tests for PowerShell module functions

### Phase 3: Coverage Metrics
- [ ] Enable coverage reporting in CI
- [ ] Set per-layer coverage targets (goal: 80%+)
- [ ] Generate coverage badges for README

### Phase 4: End-to-End Testing
- [ ] Add ephemeral VM tests (macOS/NixOS/Windows) for activation validation
- [ ] Validate security policy enforcement on live systems
- [ ] Test upgrade/rollback scenarios

---

**Last Updated**: Continuous (update this file whenever suite structure changes)
**Nix Suite Status**: 16 `tests/src/*.nix` files tracked in-repo
**Windows Suite Status**: hierarchical Pester suites under `tests/src/hosts/Windows/**`
**Shell Suite Status**: script validation checks in `tests/scripts/`
