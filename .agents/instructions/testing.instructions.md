---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates TDD practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Testing guidelines

Every feature addition or breaking change requires tests. Layout mirrors `src/` (see `AGENTS.md`). Two methodologies: Nix-based tests (macOS/NixOS) and Pester tests (Windows).

---

## Fail-fast convention

The repository's check and test scripts follow a deliberate fail-fast convention that differs between the two:

| Script | Default behavior | Rationale |
| ------------------------ | ------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `check.sh` / `check.ps1` | **NOT fail-fast** (accumulate all) | Runs on every commit; should report all issues found, not stop at the first one. |
| `test.sh` / `test.ps1` | **Fail-fast** (exit on first failure) | Runs in CI and pre-push; early exit reduces CI time and avoids masking the first failure with cascading noise. |

Both scripts accept `--fail-fast` and `--no-fail-fast` flags for explicit control over the default behavior.

The prek hooks (`prek.toml`) use the defaults (`--no-fail-fast` is not passed for check, not passed for test). The CI workflow (`.github/workflows/ci.yml`) always passes `--no-fail-fast` explicitly to both check and test, so CI reports all failures regardless of the default.

---

## Quick Start

### Run All Tests Locally

**Nix tests:**

```bash
# Evaluate core module logic tests
nix-instantiate --eval tests/modules/core-tests.nix

# Evaluate module import tests
nix-instantiate --eval tests/modules/module-imports-tests.nix

# VM setup logic tests (attr `summary`; `-A all_tests` fails — not exported)
nix-instantiate --eval --strict -A summary tests/modules/vm-setup-tests.nix

# Full flake check (all configs parse)
cd src && nix flake check
```

**Windows tests (on Windows with admin):**

```powershell
# Run Pester tests for DSC validation
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose
```

---

## Nix testing strategy

### Layer 1: Static evaluation (flake check)

`nix flake check` evaluates all host configurations without building. Catches syntax errors, unresolved imports, and missing/mistyped options. Runs on every commit (CI + local pre-commit).

### Layer 2: Pure logic tests

**Locations:** `tests/modules/*.nix`, `tests/integration/*.nix`, `tests/hosts/*/*.nix`

Test package categorization, module option defaults/constraints, conditional config logic, list filtering, and string manipulation in activation hooks. Use `nix-instantiate --eval` with assertion helpers.

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

**Force evaluation is mandatory.** Nix is lazy — a test file that only counts its tests (`success = true; testCount = builtins.length allTests;`) never forces the `assert'` thunks, so the suite reports green while no tests run. Every Nix test file MUST force evaluation with at least one construct:

- top-level `assert cond;` chains
- 2-arg `builtins.seq (builtins.deepSeq <tests> null)`
- `success = builtins.all (t: t == null) <tests>`
- `inherit test_x ...` into the result attrset (or into a deepSeq attrset)
- `builtins.filter (x: x != null) [ ... ]`
- `success = <value derived from the tests>` (e.g. `all_tests_pass`)

Prohibited patterns:

- `success = true` with only counting references (`builtins.length allTests` or `all_tests`) — tests are referenced for the count but never evaluated. Without the `deepSeq` wrapper, this is exactly the silent no-op above.
- 1-arg `builtins.seq (builtins.deepSeq <tests>)` — a partial application (lambda) in WHNF; `seq` forces nothing. See "Deadnix-reported unused bindings" below for the correct 2-arg form.

Test step 1 (`nix-test-eval` guard in `src/scripts/lib/nix-test-eval.sh` / `src/scripts/lib/nix-test-eval.ps1`) enforces this before `nix-instantiate --eval --strict` runs.

### No real-user test coupling

Tests MUST NOT reference, assert on, or read files from a specific real `src/users/<username>/` directory. Every directory under `src/users/` except `default` is a production-managed identity discovered by flake, activation, and registry loaders.

**Allowed patterns:**

| Pattern | When to use |
| --- | --- |
| `tests/fixtures/user-registry/` + `test-user` + `--repo-root` / Nix `repoRoot` | Registry, cloud-drives, symlinks, secrets-key wiring, any test needing a discovered user |
| `src/users/default/` reads | Baseline template content only (`default` is not a user) |
| Temp-dir synthetic users (`alice`, `bob`, `carol`) + `-RepoRoot` | Overlay resolution unit tests (ConfigHelpers pattern) |
| Dynamic `primaryUser` from `load-user-registry.sh` | Integration tests that must eval the live repo (system config build) — no hardcoded username string |

**Prohibited patterns:**

- Hardcoded username strings matching any `src/users/<name>/` directory (other than `default`)
- Copying production user data into test assertions (home paths, cloud paths, password-store paths from a real user)
- Adding `src/users/test-user/` or any test-only user under production `src/users/` (auto-discovered as a real user)

**Fixture conventions:** `test-user` lives only under `tests/fixtures/user-registry/src/users/`. Shared constants: `tests/fixtures/fixtures.nix` (`fixtureUsername`) and `tests/scripts/user-registry-fixture.sh` (`FIXTURE_USERNAME`). The `tests/fixtures/user-registry/src/users/default` symlink points at the live `src/users/default` tree, so edits there are production edits. Use `test-user` for isolated fixture changes.

### Layer 3: Module import validation

`tests/modules/module-imports-tests.nix` verifies all shared modules import without errors, module dependencies are acyclic, and option paths are correctly scoped.

### Test troubleshooting patterns

- **macOS regex incompatibility**: libc++ `std::regex` treats `\(` as a capturing group. Use `[(]` instead of `\(` in Nix test assertions on macOS.
- **Cascading assertion failures**: `builtins.throw` in `assert'` only reveals the first failure per eval run. Temporarily replace `assert'` with a recording no-op to find all failures at once.
- **Template refactoring ripple**: When code refactors from inline Nix strings to external template files (`builtins.readFile`), tests must read the template file. Every assertion referencing the old inline source is a latent failure.
- **Deadnix-reported unused bindings**: deadnix flags `let` bindings never forced by the return expression. These are not false positives — Nix is lazy, so unreferenced bindings are never evaluated. Remove leftover bindings; force evaluation for bindings that must be computed. `builtins.deepSeq` takes two arguments — `deepSeq a b` returns `b` after deep-forcing `a`. The one-arg form (`builtins.seq (builtins.deepSeq { ... }) { ... }`) returns a partial lambda (WHNF), so `seq` never forces anything and the test silently reports success. Canonical pattern:

    ```nix
    in
    builtins.seq (builtins.deepSeq {
      inherit binding1 binding2;
    } null) {
      success = true;
    }
    ```

    or use `(builtins.deepSeq { inherit binding1 binding2; } { result = ...; })` directly as the return expression.

  Do not suppress deadnix or exclude test files from analysis — dead code cannot catch regressions.

---

## Windows testing strategy (Pester)

**Location:** `tests/platforms/Windows/modules/**/*.Tests.ps1`

Test categories: package installation, registry configuration, file system state, and security invariants.

**Run locally:**

```powershell
# All Windows tests (requires admin)
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose

# Single file
Invoke-Pester -Path tests/platforms/Windows/modules/config-method.Tests.ps1
```

### DSC dry-run validation

Preview DSC changes without modifying system state:

```powershell
winget configure --what-if .\src\hosts\Windows\system.dsc.yml
winget configure --what-if .\src\hosts\Windows\system-packages.dsc.yml
winget configure --what-if .\src\hosts\Windows\user.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-env.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-context.dsc.yml
```

---

## Adding new tests

- **Contract-breaking change** (module options, service registry schema, cross-host parity): add or update Nix logic tests or Windows source/contract Pester tests.
- **Bug fix**: add a reproducing case when the regression is non-obvious; skip one-off migration guards.

Commit atomically: test + implementation in one commit.

**Naming:**
- Nix: `tests/<area>/<topic>-tests.nix`
- Pester: `tests/platforms/Windows/modules/<area>/<feature>.Tests.ps1`

---

## Test script gotchas

These apply to test scripts, not production code.

- **Assert-Pass style, not Pester**: tests under `tests/scripts/check-steps/` are plain `pwsh -NoProfile -File` scripts with explicit PASS/FAIL output — `Invoke-Pester` discovers 0 tests in them. Run them directly and check the exit code. They are wired into test step 5 (`script-and-framework-tests`) via auto-discovery. Step 5 runs priority framework suites serially, then dispatches remaining `tests/scripts/**/*-tests.*` in parallel with ordered output replay; `nucleus-apps-smoke-tests.sh` runs once under `nucleus_nix_locked`. When adding a new check step, follow the group-aware, rename-first ordering rule in `step-runner.instructions.md` — never blind-append the next unused number.
- **PowerShell gotchas**:
  - `exit` inside a function/script is NOT catchable by `try/catch` — `ExitException` propagates and kills the script. Tests of exit-based rejection must spawn a subprocess (`pwsh -NoProfile -Command $scriptText`) and check `$LASTEXITCODE` plus output.
  - `Write-ErrorMessage`/`Write-Message` are defined by `test-lib.ps1`, not `step-runner.ps1`. Tests asserting these are UNDEFINED (`CommandNotFoundException` catch) pass standalone but FAIL in-suite because test-lib defines them — and the test's `exit 1` really runs.
  - `& script.ps1` does NOT set `$LASTEXITCODE` (only native commands do); reading it before any native command throws under StrictMode.
  - `test.ps1` fail-fast kills the process before any summary — zero stdout. Use `--no-fail-fast` when debugging.
- **Comment content in test files**:
  - Comments in test `.sh` files must NEVER contain `__TOKEN__`-delimited names — check step 14 (`repository-policy` activation-token sub-check) greps `^\s*#.*__[A-Z][A-Z_]*__` and in scoped mode scans staged files including `tests/`. Use "double-underscore tokens" or `start-<VM_NAME>.sh` style.
  - Never put both fragments of a same-line step regex in one comment — step 14's InstallCommand sub-check regex is SAME-LINE, so a comment containing both `Assert-ToolAvailable` and `-InstallCommand` on one line fails the prek scoped hook.
- **Test script mechanics**:
  - `.sh` test scripts with shebangs MUST be executable (`chmod +x`; pre-commit hook `check-shebang-scripts-are-executable`); `.ps1` test files stay `644`.
  - `test-lib.sh`/`check-lib.sh`/`step-runner.sh` derive `REPO_ROOT` themselves — do NOT add `REPO_ROOT="$REPO_ROOT"` env-prefixes or `# shellcheck disable=SC2030,SC2031` self-assignment pairs. `bash -c` children use parent-spliced paths only (e.g. `. "'"$REPO_ROOT"'/src/scripts/lib/step-runner.sh"`).
  - `cache_file_lists()` in `step-runner.sh` fills arrays with `readarray -t`; test stubs must initialize `CACHED_*_FILES=()` first (SC2178).

---

## CI integration

Tests run on push, pull request, and manual dispatch. POSIX CI runs `nix run ./src#test` (Nix eval, framework tests including nucleus-apps smoke via step 5 auto-discovery, system build). Windows CI runs `bootstrap.ps1` (provisions Pester and other pwsh modules), then `test.ps1` including step 6 (`windows-pester`). Pester is lockfile-pinned and preflight-checked — provisioning and preflight are separate (see `tooling-and-validation.instructions.md`).

---

## Validation checklist

Before committing, verify:

- [ ] All Nix tests pass: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`
- [ ] Flake checks pass: `cd src && nix flake check`
- [ ] Shell syntax passes: `nix run ./src#check-sh`
- [ ] PowerShell syntax (pre-commit): `pwsh -File scripts/check-pwsh.ps1 -SkipStep PSSA`
- [ ] PowerShell PSSA (pre-push): `pwsh -File scripts/check-pwsh.ps1 -SkipStep Syntax -Settings scripts/test-PSScriptAnalyzerSettings.psd1`
- [ ] (Windows only) Pester: `pwsh -File scripts/test.ps1 --skip-steps=nix-tests,system-config-build` or step 6 only
