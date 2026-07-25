---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates test-driven development (TDD) practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/hosts/Windows/modules/**/*.ps1, tests/scripts/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Test-Driven Development Practices

## Overview

**nucleus** uses automated testing to catch regressions and validate that declarative configuration applies correctly across macOS, NixOS, and Windows. Tests are split into two distinct methodologies:

- **Nix-based tests** (macOS/NixOS): Pure evaluation checks and unit tests
- **Pester tests** (Windows): Runtime validation of DSC resources

Tests must accompany every feature or breaking change. Ensure tests pass locally before submitting PRs.

---

## Fail-fast convention

The repository's check and test scripts follow a deliberate fail-fast convention that differs between the two:

| Script                   | Default behavior                      | Rationale                                                                                                      |
| ------------------------ | ------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `check.sh` / `check.ps1` | **NOT fail-fast** (accumulate all)    | Runs on every commit; should report all issues found, not stop at the first one.                               |
| `test.sh` / `test.ps1`   | **Fail-fast** (exit on first failure) | Runs in CI and pre-push; early exit reduces CI time and avoids masking the first failure with cascading noise. |

Both scripts accept `--fail-fast` and `--no-fail-fast` flags for explicit control over the default behavior.

The prek hooks (`prek.toml`) use the defaults (`--no-fail-fast` is not passed for check, not passed for test). The CI workflow (`.github/workflows/ci.yml`) always passes `--no-fail-fast` explicitly to both check and test, ensuring CI reports all failures regardless of the default.

---

## Quick Start

### Run All Tests Locally

**Nix tests:**

```bash
# Evaluate core module logic tests
nix-instantiate --eval tests/modules/core-tests.nix

# Evaluate module import tests
nix-instantiate --eval tests/modules/module-imports-tests.nix

# Full flake check (all configs parse)
cd src && nix flake check
```

**Windows tests (on Windows with admin):**

```powershell
# Run Pester tests for DSC validation
Invoke-Pester -Path tests/hosts/Windows/ -Verbose
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

**File locations:** `tests/modules/*.nix`, `tests/integration/*.nix`, `tests/hosts/*/*.nix`

**What to test:**

- Package categorization logic (CLI vs. GUI → backend selection)
- Module option defaults and constraints
- Conditional logic in configuration (e.g., OS-specific paths)
- List filtering and transformations
- String manipulation used in activation hooks

**Test structure:** Use `nix-instantiate --eval` with assertion helpers.

**Example:**

```nix
# tests/modules/package-parity-tests.nix (excerpt)
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

**Run:** `nix-instantiate --eval tests/modules/package-parity-tests.nix`

### Layer 3: Module Import Validation

**File location:** `tests/modules/module-imports-tests.nix`

**What to test:**

- All shared modules can be imported without errors
- Module dependencies are acyclic
- Option paths are correctly scoped

**Why it's important:** Catches circular dependencies and typos in module paths before CI fails.

### Test troubleshooting patterns

These patterns have been learned from fixing real test failures:

- **macOS regex incompatibility**: libc++ `std::regex` treats `\(` as a capturing group, not a literal parenthesis. Use character classes like `[(]` instead of `\(` in Nix test assertions evaluated on macOS.
- **Cascading assertion failures**: `builtins.throw` in assertion helpers (e.g., `assert'`) only reveals the first failure per eval run. To find all failures at once, temporarily replace `assert'` with a no-op version that records rather than throws.
- **Template refactoring ripple**: When code refactors from inline Nix strings to external template files (`builtins.readFile`), tests that previously checked the Nix source file must be updated to read the template file instead. Every assertion that references the old inline source is a latent failure.
- **Deadnix-reported unused bindings**: deadnix flags `let` bindings in test files that are never forced by the final return expression. These are **not false positives** — Nix is lazy, so bindings unreferenced from the expression tree are genuinely never evaluated. If deadnix flags a binding:
  - **Remove it** if it was leftover from an earlier version of the test.
  - **Force evaluation** if the binding must be computed for correctness. The canonical pattern:

    ```nix
    in
    builtins.seq (builtins.deepSeq {
      inherit binding1 binding2;
    }) {
      success = true;
    }
    ```

  - Do **not** suppress deadnix or exclude test files from analysis — dead code that is never evaluated cannot catch regressions.

---

## Windows Testing Strategy (Pester)

### Pester Test Structure

**File location:** `tests/hosts/Windows/**/*.Tests.ps1`

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
Invoke-Pester -Path tests/hosts/Windows/ -Verbose

# Run a single test file
Invoke-Pester -Path tests/hosts/Windows/packages/package-installation.Tests.ps1
```

### DSC Dry-Run Validation

Before applying DSC changes, preview them without modifying system state:

```powershell
# Preview system-level changes (baseline + packages)
winget configure --what-if .\src\hosts\Windows\system.dsc.yml
winget configure --what-if .\src\hosts\Windows\system-packages.dsc.yml

# Preview user-level changes (settings, env vars, context menu)
winget configure --what-if .\src\hosts\Windows\user.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-env.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-context.dsc.yml
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

- `tests/<area>/<topic>-tests.nix` — logic tests organized by scope
- Examples: `tests/modules/core-tests.nix`, `tests/integration/cloud-sync-tests.nix`, `tests/hosts/MacBook/alttab-settings-tests.nix`

**Pester tests:**

- `tests/hosts/Windows/<area>/<feature>.Tests.ps1` — tests for a feature or DSC resource group
- Example: `tests/hosts/Windows/system/system-policy.Tests.ps1` for machine-scoped DSC invariants

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

- [ ] All Nix tests pass: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`
- [ ] Flake checks pass: `cd src && nix flake check`
- [ ] Shell syntax passes: `nix run ./src#check-sh`
- [ ] PowerShell syntax passes: `nix run ./src#check-pwsh`
- [ ] (Windows only) Pester tests pass: `Invoke-Pester tests/hosts/Windows/`
