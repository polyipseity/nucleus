---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates test-driven development (TDD) practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
applyTo: "src/**/*.nix, src/hosts/windows/**/*.yml, src/hosts/windows/modules/*.ps1, tests/**, .github/workflows/**"
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
nix-instantiate --eval tests/nix/core-tests.nix

# Evaluate module import tests
nix-instantiate --eval tests/nix/module-imports-tests.nix

# Full flake check (all configs parse)
cd src && nix flake check
```

**Windows tests (on Windows with admin):**

```powershell
# Run Pester tests for DSC validation
Invoke-Pester -Path tests/windows/ -Verbose
```

**CI validation:**

```bash
# Runs automatically on push/PR; can be simulated locally
nix run ./src#check-sh  # Shell syntax
nix run ./src#check-pwsh  # PowerShell syntax
cd src && nix flake check  # Nix evaluation
nix-instantiate --eval tests/nix/*.nix  # Nix unit tests
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

**File location:** `tests/nix/*.nix`

**What to test:**

- Package categorization logic (CLI vs. GUI → backend selection)
- Module option defaults and constraints
- Conditional logic in configuration (e.g., OS-specific paths)
- List filtering and transformations
- String manipulation used in activation hooks

**Test structure:** Use `nix-instantiate --eval` with assertion helpers.

**Example:**

```nix
# tests/nix/package-logic.nix
{ lib ? import <nixpkgs/lib> }:
let
  assert' = cond: msg: if !cond then builtins.throw msg else null;

  # Test: package backend selection
  test_backend_selection = assert'
    (lib.attrNames { cli = true; gui = true; } == [ "cli" "gui" ] || true)
    "Backend categorization failed";
in
{
  success = true;
  message = "All package logic tests passed";
}
```

**Run:** `nix-instantiate --eval tests/nix/package-logic.nix`

### Layer 3: Module Import Validation

**File location:** `tests/nix/module-imports-tests.nix`

**What to test:**

- All shared modules can be imported without errors
- Module dependencies are acyclic
- Option paths are correctly scoped

**Why it's important:** Catches circular dependencies and typos in module paths before CI fails.

---

## Windows Testing Strategy (Pester)

### Pester Test Structure

**File location:** `tests/windows/**/*.Tests.ps1`

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
Invoke-Pester -Path tests/windows/ -Verbose

# Run a single test file
Invoke-Pester -Path tests/windows/packages/package-installation.Tests.ps1
```

### DSC Dry-Run Validation

Before applying DSC changes, preview them without modifying system state:

```powershell
# Preview system-level changes
winget configure --what-if .\src\hosts\windows\system.dsc.yml

# Preview user-level changes
winget configure --what-if .\src\hosts\windows\user.dsc.yml
```

---

## Adding New Tests

### When to Write Tests

- **New Nix module:** Add unit tests to `tests/nix/` for any logic beyond simple declarations
- **New DSC resource:** Add Pester test to `tests/windows/` to verify state after apply
- **Module changes:** Update existing tests if logic changes
- **Bug fix:** Add a test case that reproduces the bug, then verify the fix passes

### Test-Driven Development (TDD) Workflow

1. **Write the test first** — describe what correct behavior looks like
2. **Watch it fail** — confirm the test catches the missing feature
3. **Implement the feature** — make the test pass
4. **Refactor if needed** — improve code while tests stay green
5. **Commit atomically** — test + implementation in one commit

### Naming Conventions

**Nix tests:**
- `tests/nix/<module>-tests.nix` — logic tests for a specific module
- Example: `tests/nix/core-tests.nix` for core.nix logic

**Pester tests:**
- `tests/windows/<area>/<feature>.Tests.ps1` — tests for a feature or DSC resource group
- Example: `tests/windows/system/system-policy.Tests.ps1` for machine-scoped DSC invariants

### Example: Add a Test for a New Package

**Scenario:** You're adding a new CLI tool `ripgrep` to the overlappingPackages table in core.nix.

**Step 1: Write the Pester test** (on Windows)

```powershell
# tests/windows/cli-tools.Tests.ps1
Describe "CLI Tools" {
    It "Should have ripgrep installed" {
        $pkg = winget list --exact -q "BurntSushi.ripgrep.MSVC"
        $pkg | Should -Not -BeNullOrEmpty
    }
}
```

**Step 2: Run the test and watch it fail**

```powershell
Invoke-Pester tests/windows/cli-tools.Tests.ps1
# Test fails: ripgrep not found
```

**Step 3: Add ripgrep to src/hosts/windows/system.dsc.yml**

```yaml
- resource: Microsoft.WinGet.Client/Package
  directives:
    description: Ensure ripgrep is installed for fast recursive text search
  settings:
    id: BurntSushi.ripgrep.MSVC
    source: winget
```

**Step 4: Run the test again (should pass after `apply.ps1`)**

```powershell
Invoke-Pester tests/windows/cli-tools.Tests.ps1
# Test passes: ripgrep found
```

**Step 5: Commit atomically**

```bash
git add tests/windows/cli-tools.Tests.ps1 src/hosts/windows/system.dsc.yml
git commit -S -m "feat(windows): add ripgrep for fast text search

- Add ripgrep to system.dsc.yml for cross-host CLI parity
- Add Pester test to validate installation
- Ripgrep mirrors fd behavior on POSIX hosts"
```

---

## CI Integration

### GitHub Actions Workflow

Tests run automatically on:
- Every push to any branch
- Every pull request
- Manual workflow dispatch

**Current CI steps:**

1. **Checkout repository** — get latest code
2. **Install Nix** — bootstrap nixpkgs environment
3. **Nix flake check** — ensure all configs parse
4. **Nix unit tests** — run logic tests with `nix-instantiate --eval`
5. **PowerShell syntax check** — validate all `.ps1` files
6. **Shell script check** — validate all `.sh` files

**Windows-specific tests:** Not run in CI (uses Linux runners). Run locally before commit.

### Viewing CI Results

1. Go to the PR or commit in GitHub
2. Click "Details" on the CI status check
3. View the "Logs" tab to see test output
4. Fix failures and push a new commit

---

## Troubleshooting

### Test Failure: "Undefined option namespace"

**Cause:** A Nix module imports a feature module that's not properly scoped.

**Fix:** Ensure all module options are declared with `lib.mkOption` and are at the correct hierarchy level.

### Test Failure: Pester "Package not found"

**Cause:** Test ran before `apply.ps1` finished, or package wasn't installed correctly.

**Fix:**
1. Verify DSC syntax: `winget configure --what-if .\src\hosts\windows\*.dsc.yml`
2. Run apply manually: `.\src\scripts\bootstrap.ps1`
3. Wait for package manager to finish installing
4. Re-run Pester: `Invoke-Pester tests/windows/`

### Test Failure: "Permission denied" (Pester)

**Cause:** Pester tests require admin privileges to read registry and check installations.

**Fix:** Run PowerShell as Administrator before calling `Invoke-Pester`.

### Flake Check Hangs or Times Out

**Cause:** A module evaluation is infinite-looping or fetching large derivations.

**Fix:**
1. Interrupt the check: `Ctrl+C`
2. Check recent `.nix` changes for recursive imports or infinite loops
3. Use `nix-instantiate --parse` to do a syntax-only check (no evaluation)
4. Revert the last change and debug incrementally

---

## Validation Checklist

Before committing changes, verify:

- [ ] All Nix tests pass: `nix-instantiate --eval tests/nix/*.nix`
- [ ] Flake checks pass: `cd src && nix flake check`
- [ ] Shell syntax passes: `nix run ./src#check-sh`
- [ ] PowerShell syntax passes: `nix run ./src#check-pwsh`
- [ ] (Windows only) Pester tests pass: `Invoke-Pester tests/windows/`
- [ ] Commit message follows conventional commits (e.g., `test(nix): ...`, `feat(windows): ...`)
- [ ] Commit is atomic (one logical change, not a mix of unrelated changes)
- [ ] No `--no-verify` bypasses; pre-commit hooks must pass

---

## References

- [AGENTS.md](../AGENTS.md) — Repository-wide testing strategy overview
- [nix-instantiate(1)](https://nixos.org/manual/nix/stable/command-ref/nix-instantiate.html) — Nix static evaluation tool
- [Pester Documentation](https://pester.dev) — PowerShell testing framework
- [WinGet DSC](https://learn.microsoft.com/en-us/windows/package-manager/configuration/) — Windows Desired State Configuration
