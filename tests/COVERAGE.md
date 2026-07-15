# Nucleus test coverage summary

## Overview

This document summarizes test coverage across all nucleus platforms (macOS, NixOS, Windows) and layers (Nix, PowerShell, shell). The suite validates configuration logic, module composition, package parity, and deployment scripts. Run `find tests/modules tests/integration tests/hosts -name '*.nix'` for the authoritative list of Nix test files, and `find tests/hosts/Windows -name '*.ps1'` for Windows Pester suites.

---

## Test suite structure

Nix tests live in `tests/modules/`, `tests/integration/`, and `tests/hosts/<host>/`, run via `nix-instantiate --eval` in CI. They cover module options, import graphs, config composition, package parity, option conflict detection, activation dependency ordering, SOPS structure validation, and VS Code extension pruning.

Windows tests live in `tests/hosts/Windows/`, organized by concern (`apps/`, `configuration/`, `packages/`, `smoke/`, `system/`), run via Pester. They cover cross-host CLI parity, developer runtimes, GUI applications, registry/policy invariants, and DSC state validation.

Nucleus apps smoke tests (`tests/scripts/nucleus-apps-smoke-tests.sh`) run via `nix run ./src#test` with three tiers: `--help` invocation (all 18 nucleus-* commands), `--dry-run` (commands with dry-run support), and safe no-op (read-only commands; `svc list --json` is skipped — it requires `sudo` for system-domain services).

Shell script validation (`tests/scripts/script-validation-tests.sh`) runs via bash in CI, covering bash syntax, shebangs, executable bits, dependency availability, error handling, dangerous pattern detection, and portability.

Consolidated check scripts (`scripts/check.sh` for POSIX, `scripts/check.ps1` for Windows) delegate to existing checkers without logic duplication; path-scoped mode skips whole-repo checks when arguments are provided.

---

## CI integration

All tests run automatically via `.github/workflows/ci.yml` on every commit: Nix parse (`nix flake check`), POSIX checks (`nix run ./src#check`), POSIX test suite (`nix run ./src#test`), Windows checks (`pwsh -File scripts/check.ps1`), and Windows test suite (`pwsh -File scripts/test.ps1`).

---

## Coverage by platform

### macOS

Nix configuration (full), package selection/Homebrew parity (full), activation hooks (partial, manual), security policies (full).

### NixOS

Nix configuration (full), package selection/nixpkgs parity (full), activation hooks (partial, manual), security policies (full).

### Windows

WinGet DSC (full), PowerShell modules (partial, syntax only), activation hooks (partial, manual), security policies/registry invariants (full).

---

## Untested areas

Activation hooks, secret decryption, and deployment validation require live systems and are not unit-testable in CI. Mock tests cover secret structure.

---

## Test execution

```bash
# All Nix tests
nix flake check src/
find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +

# Windows Pester tests
pwsh -Command "Invoke-Pester tests/hosts/Windows/"

# Shell script validation
bash tests/scripts/script-validation-tests.sh

# CI locally (requires act: https://github.com/nektos/act)
act push --job test
```

---

- **Last updated**: continuous (update when suite structure changes).
