---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates test-driven development (TDD) practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/hosts/Windows/modules/**/*.ps1, .github/workflows/**"
---

# Test-Driven Development Practices

## Overview

**nucleus** uses automated testing to catch regressions and validate that declarative configuration applies correctly across macOS, NixOS, and Windows. Tests are split into two distinct methodologies:

- **Nix-based tests** (macOS/NixOS): Pure evaluation checks and unit tests
- **Pester tests** (Windows): Runtime validation of DSC resources

Tests must accompany every feature or breaking change. Ensure tests pass locally before submitting PRs.

---

## Quick Start

### Run All Tests Locally

**Nix tests:**

```bash
# Evaluate core module logic tests
nix-instantiate --eval tests/src/core-tests.nix

# Evaluate module import tests
nix-instantiate --eval tests/src/module-imports-tests.nix

# Full flake check (all configs parse)
cd src && nix flake check
```

**Windows tests (on Windows with admin):**

```powershell
# Run Pester tests for DSC validation
Invoke-Pester -Path tests/src/hosts/Windows/ -Verbose
```

---

## Nix Testing Strategy

### Layer 1: Static Evaluation (Flake Check)

`nix flake check` evaluates all host configurations without building them, catching:

- Syntax errors in `.nix` files
- Unresolved module imports
- Missing or mistyped options

**When it runs:** CI on every commit; part of local pre-commit.

**Why it's important:** Prevents "broken commits" from ever being applied to live machines.

### Layer 2: Pure Logic Tests

**File location:** `tests/src/*.nix`

**What to test:**

- Package categorization logic (CLI vs. GUI → backend selection)
- Module option defaults and constraints
- Conditional logic in configuration (e.g., OS-specific paths)
- List filtering and transformations
- String manipulation used in activation hooks

**Test structure:** Use `nix-instantiate --eval` with assertion helpers.

**Example:**

```nix
# tests/src/package-parity-tests.nix (excerpt)
{
  lib ? import <nixpkgs/lib>,
}:
let
  assert' = cond: msg: if !cond then builtins.throw msg else null;

  # Test: cross-platform package ID parity.
  test_ripgrep_parity = assert' (
    builtins.elem "ripgrep" [ "git" "ripgrep" "zsh" ]
  ) "ripgrep parity mapping missing";
in
{
  success = true;
  message = "Package parity checks passed";
}
```

**Run:** `nix-instantiate --eval tests/src/package-parity-tests.nix`

### Layer 3: Module Import Validation

**File location:** `tests/src/module-imports-tests.nix`

**What to test:**

- All shared modules can be imported without errors
- Module dependencies are acyclic
- Option paths are correctly scoped

**Why it's important:** Catches circular dependencies and typos in module paths before CI fails.

---

## Windows Testing Strategy (Pester)

### Pester Test Structure

**File location:** `tests/src/hosts/Windows/**/*.Tests.ps1`

**Test categories:**

1. **Package Installation** — Verify WinGet packages are installed
2. **Registry Configuration** — Verify registry keys match declarative intent
3. **File System State** — Verify folders/files exist at correct paths
4. **Security Invariants** — Verify lock timeout, password requirements, etc.

**Example Pester test:**

```powershell
Describe "Windows Package Installation" {
    It "Should have zoxide installed" {
        $pkg = winget list --exact -q "ajeetdsouza.zoxide" | Where-Object { $_ -like "*zoxide*" }
        $pkg | Should -Not -BeNullOrEmpty
    }
}

Describe "Security Settings" {
    It "Should enforce immediate lock on screen saver" {
        $regPath = "HKCU:\Control Panel\Desktop"
        $value = Get-ItemProperty -Path $regPath -Name ScreenSaveTimeout -ErrorAction SilentlyContinue
        [int]$value.ScreenSaveTimeout | Should -BeLessThanOrEqual 60
    }
}
```

**Run locally:**

```powershell
# Run all Windows tests (requires admin)
Invoke-Pester -Path tests/src/hosts/Windows/ -Verbose

# Run a single test file
Invoke-Pester -Path tests/src/hosts/Windows/packages/package-installation.Tests.ps1
```

### DSC Dry-Run Validation

Before applying DSC changes, preview them without modifying system state:

```powershell
# Preview system-level changes
winget configure --what-if .\src\hosts\Windows\system.dsc.yml

# Preview user-level changes
winget configure --what-if .\src\hosts\Windows\user.dsc.yml
```

---

## Adding New Tests

### When to Write Tests

- New feature or breaking change: tests required (logic tests for Nix, Pester for DSC).
- Bug fix: add a case that reproduces the bug, then verify the fix passes.

### Test-Driven Development (TDD) Workflow

Commit atomically: test + implementation in one commit.

### Naming Conventions

**Nix tests:**

- `tests/src/<module>-tests.nix` — logic tests for a specific module
- Example: `tests/src/core-tests.nix` for core.nix logic

**Pester tests:**

- `tests/src/hosts/Windows/<area>/<feature>.Tests.ps1` — tests for a feature or DSC resource group
- Example: `tests/src/hosts/Windows/system/system-policy.Tests.ps1` for machine-scoped DSC invariants

### Example patterns

**Pester test for package installation:**

```powershell
Describe "Windows Package Installation" {
  It "Should have <tool> installed" {
    winget list --exact -q "<Publisher>.<Tool>" | Should -Not -BeNullOrEmpty
  }
}
```

---

## CI Integration

Tests run automatically on push, pull request, and manual dispatch. CI runs `nix flake check`, Nix unit tests, PowerShell syntax check, and shell script check. Windows-specific tests not run in CI (uses Linux runners); run locally before commit.



---

## Validation Checklist

Before committing changes, verify:

- [ ] All Nix tests pass: `nix-instantiate --eval tests/src/*.nix`
- [ ] Flake checks pass: `cd src && nix flake check`
- [ ] Shell syntax passes: `nix run ./src#check-sh`
- [ ] PowerShell syntax passes: `nix run ./src#check-pwsh`
- [ ] (Windows only) Pester tests pass: `Invoke-Pester tests/src/hosts/Windows/`
