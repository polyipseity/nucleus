---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates test-driven development (TDD) practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Test-Driven Development Practices

## Overview

**nucleus** uses automated testing to catch regressions and validate that declarative configuration applies correctly across macOS, NixOS, and Windows. Tests are split into two distinct methodologies:

- **Nix-based tests** (macOS/NixOS): Pure evaluation checks and unit tests
- **Pester tests** (Windows): Runtime validation of DSC resources

Tests must accompany every feature or breaking change. Ensure tests pass locally before submitting PRs.

**Tests mirror `src/`:** `tests/hosts/<Host>/`, `tests/platforms/<Platform>/`, `tests/modules/` (cross-host shared), plus `tests/integration/` and `tests/scripts/`. Rule: `src/<layer>/...` → `tests/<layer>/...`.

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
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose
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
builtins.seq (builtins.deepSeq {
  inherit test_ripgrep_parity;
} null) {
  success = true;
  message = "Package parity checks passed";
}
```

**Run:** `nix-instantiate --eval --strict tests/modules/package-parity-tests.nix`

**Force evaluation is mandatory.** Nix is lazy — a test file that only counts its tests (`success = true; testCount = builtins.length allTests;`) never forces the `assert'` thunks, so the suite reports green while no test actually runs. Every Nix test file MUST force evaluation of every test binding with at least one of these constructs:

- top-level `assert cond;` chains
- 2-arg `builtins.seq (builtins.deepSeq <tests> null)`
- `success = builtins.all (t: t == null) <tests>`
- `inherit test_x ...` into the result attrset (or into a deepSeq attrset)
- `builtins.filter (x: x != null) [ ... ]`
- `success = <value derived from the tests>` (e.g. `all_tests_pass`)

Prohibited patterns:

- `success = true` with only counting references (`builtins.length allTests` or `all_tests`) — the tests are referenced for the count but never evaluated. Without the `deepSeq` wrapper the example above is exactly this silent no-op.
- 1-arg `builtins.seq (builtins.deepSeq <tests>)` — a partial application (lambda) in WHNF; `seq` forces nothing. See "Deadnix-reported unused bindings" below for the correct 2-arg form.

Test step 1 (`nix-test-eval` guard in `src/scripts/lib/nix-test-eval.sh` / `src/scripts/lib/nix-test-eval.ps1`) enforces this before `nix-instantiate --eval --strict` runs.

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
  - **Force evaluation** if the binding must be computed for correctness. `builtins.deepSeq` takes TWO arguments — `deepSeq a b` returns `b` after deep-forcing `a`. The one-arg form (`builtins.seq (builtins.deepSeq { ... }) { ... }`) returns a partial lambda (WHNF), so `seq` never forces the assertions and the test silently reports success. The canonical pattern:

    ```nix
    in
    builtins.seq (builtins.deepSeq {
      inherit binding1 binding2;
    } null) {
      success = true;
    }
    ```

    or use `(builtins.deepSeq { inherit binding1 binding2; } { result = ...; })` directly as the return expression.

  - Do **not** suppress deadnix or exclude test files from analysis — dead code that is never evaluated cannot catch regressions.

---

## Windows Testing Strategy (Pester)

### Pester Test Structure

**File location:** `tests/platforms/Windows/modules/**/*.Tests.ps1`

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
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose

# Run a single test file
Invoke-Pester -Path tests/platforms/Windows/modules/config-method.Tests.ps1
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

- Contract-breaking change (module options, service registry schema, cross-host parity): add or update Nix logic tests or Windows source/contract Pester tests.
- Bug fix: add a case that reproduces the bug when the regression is non-obvious; skip one-off migration guards.

### Test-Driven Development (TDD) Workflow

Commit atomically: test + implementation in one commit.

### Naming Conventions

**Nix tests:**

- `tests/<area>/<topic>-tests.nix` — logic tests organized by scope
- Examples: `tests/modules/core-tests.nix`, `tests/integration/env-parity-tests.nix`, `tests/hosts/MacBook/command-line-tools-tests.nix`

**Pester tests:**

- `tests/platforms/Windows/modules/<area>/<feature>.Tests.ps1` — tests for a feature or DSC resource group
- Example: `tests/platforms/Windows/modules/svc-windows.Tests.ps1` for machine-scoped DSC invariants

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

## Test script gotchas

Learned from authoring `tests/scripts/` check-step tests; applies to test scripts, not production code.

- **Assert-Pass style, not Pester**: functional tests under `tests/scripts/check-steps/` (e.g. `09-schema-validation-tests.ps1`) are plain `pwsh -NoProfile -File` scripts with explicit PASS/FAIL output — `Invoke-Pester` discovers 0 tests in them. Run them directly and check the exit code; they are wired into test step 5 (`script-and-framework-tests`) via auto-discovery.
- **PowerShell gotchas**:
  - `exit` inside a function/script is NOT catchable by `try/catch` — `ExitException` propagates and kills the script. Tests of exit-based rejection must spawn a subprocess (`pwsh -NoProfile -Command $scriptText`) and check `$LASTEXITCODE` plus output.
  - `Write-ErrorMessage`/`Write-Message` are defined by `test-lib.ps1`, not `step-runner.ps1`. Tests asserting these are UNDEFINED (`CommandNotFoundException` catch) pass standalone but FAIL in-suite because test-lib defines them — and the test's `exit 1` really runs.
  - `& script.ps1` does NOT set `$LASTEXITCODE` (only native commands do); reading it before any native command throws under StrictMode.
  - `test.ps1` fail-fast kills the process before any summary — zero stdout. Use `--no-fail-fast` when debugging.
- **Comment content in test files**:
  - Comments in test `.sh` files must NEVER contain `__TOKEN__`-delimited names — step 16 (`16-activation-token-placeholder`) greps `^\s*#.*__[A-Z][A-Z_]*__` and in scoped mode scans staged files including `tests/`. Refer to them as "double-underscore tokens" or `start-<VM_NAME>.sh` style.
  - Never put both fragments of a same-line step regex in one comment — step 17's `Assert-ToolAvailable`/`-InstallCommand` regex is SAME-LINE, so a comment containing both fragments on one line fails the prek scoped hook.
- **Test script mechanics**:
  - `.sh` test scripts with shebangs MUST be executable (`chmod +x`; pre-commit hook `check-shebang-scripts-are-executable`); `.ps1` test files stay `644`.
  - `test-lib.sh`/`check-lib.sh`/`step-runner.sh` derive `REPO_ROOT` themselves — do NOT add `REPO_ROOT="$REPO_ROOT"` env-prefixes or `# shellcheck disable=SC2030,SC2031` self-assignment pairs. `bash -c` children in tests use parent-spliced paths only (e.g. `. "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"`).
  - `cache_file_lists()` in `step-runner.sh` fills arrays with `readarray -t`; test stubs must initialize `CACHED_*_FILES=()` first (SC2178).
- **`test.sh` output buffering**: `test.sh` buffers ALL output until completion — the log stays 0 bytes for ~15 minutes. Run it in an async terminal and poll with `pgrep`; do not assume failure from an empty log.

---

## CI Integration

Tests run on push, pull request, and manual dispatch. POSIX CI runs `nix run ./src#test` (Nix eval, framework tests, nucleus-apps smoke, system build). Windows CI runs `bootstrap.ps1` (provisions Pester and other pwsh modules), then `test.ps1` including step 6 (`windows-pester`). Pester is lockfile-pinned and preflight-checked like other tools — provisioning and preflight are separate (see `tool-availability.instructions.md`).

---

## Validation Checklist

Before committing changes, verify:

- [ ] All Nix tests pass: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`
- [ ] Flake checks pass: `cd src && nix flake check`
- [ ] Shell syntax passes: `nix run ./src#check-sh`
- [ ] PowerShell syntax passes: `nix run ./src#check-pwsh`
- [ ] (Windows only) Pester tests pass: `pwsh -File scripts/test.ps1 --skip-steps=nix-tests,system-config-build` or step 6 only
