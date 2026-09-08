---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates TDD practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Testing guidelines

Every feature addition or breaking change requires tests. Layout mirrors `src/` (see `AGENTS.md`). Two methodologies: Nix-based tests (macOS/NixOS) and Pester tests (Windows).

## Fail-fast convention

| Script | Default | Rationale |
| ------------------------ | ------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `check.sh` / `check.ps1` | **NOT fail-fast** (accumulate all) | Runs on every commit; report all issues. |
| `test.sh` / `test.ps1` | **Fail-fast** (exit on first failure) | CI/push; early exit reduces noise and CI time. |

Both accept `--fail-fast` / `--no-fail-fast`. prek hooks use defaults; CI always passes `--no-fail-fast` explicitly.

## Quick start

```bash
# Nix tests
nix-instantiate --eval tests/modules/core-tests.nix
nix-instantiate --eval tests/modules/module-imports-tests.nix
nix-instantiate --eval --strict -A summary tests/modules/vm-setup-tests.nix  # VM setup (attr `summary`)
cd src && nix flake check
```

```powershell
# Windows tests (admin required)
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose
```

## Nix testing strategy

### Layer 1: Static evaluation (flake check)

`nix flake check` evaluates all host configs without building. Catches syntax errors, unresolved imports, mistyped options. Runs every commit.

### Layer 2: Pure logic tests

**Locations:** `tests/modules/*.nix`, `tests/integration/*.nix`, `tests/hosts/*/*.nix`

Uses `nix-instantiate --eval` with assertion helpers for package categorization, option defaults/constraints, conditional logic, list filtering, string manipulation.

**Example:**

```nix
{
  lib ? import <nixpkgs/lib>,
}:
let
  assert' = cond: msg: if !cond then builtins.throw msg else null;
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

Run: `nix-instantiate --eval --strict tests/modules/package-parity-tests.nix`

**Force evaluation is mandatory.** Nix is lazy — test files that only count tests never force `assert'` thunks, reporting green with zero tests run. Use `assert cond;`, `builtins.seq (builtins.deepSeq <tests> null)`, `builtins.all`, or `success = <derived value>`. Enforced by test step 1 (`nix-test-eval` in `src/scripts/lib/nix-test-eval.sh` / `.ps1`).

Prohibited: `success = true` with only counting refs (`builtins.length`); 1-arg `builtins.seq (builtins.deepSeq <tests>)` (WHNF, forces nothing).

### No real-user test coupling

Tests must not reference real `src/users/<username>/` directories (except `default` — production-managed identity).

| Pattern | When |
| --- | --- |
| `tests/fixtures/user-registry/` + `test-user` + `--repo-root` | Registry, cloud-drives, symlinks, any discovered-user test |
| `src/users/default/` reads | Baseline template content only |
| Temp-dir users (`alice`, `bob`) + `-RepoRoot` | Overlay resolution unit tests (ConfigHelpers) |
| Dynamic `primaryUser` from `load-user-registry.sh` | Integration tests evaling live repo |

**Prohibited:** hardcoded usernames matching production dirs, copying production data into assertions, test-only users under production `src/users/`.

**Fixtures:** `test-user` under `tests/fixtures/user-registry/src/users/`. Constants: `tests/fixtures/fixtures.nix` (`fixtureUsername`), `tests/scripts/user-registry-fixture.sh` (`FIXTURE_USERNAME`). `tests/fixtures/user-registry/src/users/default` symlinks to live tree — edits are production edits.

### Layer 3: Module import validation

`tests/modules/module-imports-tests.nix` verifies all shared modules import cleanly, dependencies are acyclic, option paths correctly scoped.

### Test troubleshooting patterns

- **macOS regex**: libc++ `std::regex` treats `\(` as capturing group. Use `[(]`.
- **Cascading failures**: `assert'` only reveals first failure. Replace with recording no-op to find all.
- **Template refactoring**: tests must read template files after inline→`builtins.readFile` moves.
- **Deadnix**: flags `let` bindings not forced by return expression. Remove or force. Canonical `deepSeq` pattern:
    ```nix
    builtins.seq (builtins.deepSeq {
      inherit binding1 binding2;
    } null) { success = true; }
    ```
  Do not suppress deadnix — dead code cannot catch regressions.

## Windows testing strategy (Pester)

**Location:** `tests/platforms/Windows/modules/**/*.Tests.ps1`

Covers package installation, registry, file system state, security invariants.

```powershell
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose           # all (admin)
Invoke-Pester -Path tests/platforms/Windows/modules/config-method.Tests.ps1  # single
```

### DSC dry-run

```powershell
winget configure --what-if .\src\hosts\Windows\system.dsc.yml
winget configure --what-if .\src\hosts\Windows\system-packages.dsc.yml
winget configure --what-if .\src\hosts\Windows\user.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-env.dsc.yml
winget configure --what-if .\src\hosts\Windows\user-context.dsc.yml
```

## Adding new tests

- **Contract-breaking change** (module options, service registry schema, cross-host parity): add Nix logic tests or Pester tests.
- **Bug fix**: add reproducing case when regression is non-obvious.

Commit atomically: test + implementation in one commit.

**Naming:** Nix: `tests/<area>/<topic>-tests.nix`; Pester: `tests/platforms/Windows/modules/<area>/<feature>.Tests.ps1`

---

## Test script gotchas

Test scripts only, not production code.

- **Assert-Pass style**: `tests/scripts/check-steps/` are plain pwsh scripts with PASS/FAIL output — Pester discovers 0 tests. Run directly, check exit code. Wired into step 5 (`script-and-framework-tests`). Follow group-aware rename-first rules from `step-runner.instructions.md`.
- **PowerShell**:
  - `exit` is not catchable by `try/catch` — spawn subprocess, check `$LASTEXITCODE` + output.
  - `Write-ErrorMessage`/`Write-Message` from `test-lib.ps1` — tests asserting UNDEFINED pass standalone but fail in-suite.
  - `& script.ps1` does not set `$LASTEXITCODE`.
  - `test.ps1` fail-fast kills process before summary. Use `--no-fail-fast` for debugging.
- **Comments**: no `__TOKEN__`-delimited names in `.sh` test comments (step 14 greps). No both fragments of same-line regex in one comment (step 14 SAME-LINE).
- **Mechanics**: `.sh` with shebangs must be executable; `.ps1` stay 644. Libs derive `REPO_ROOT` themselves. `cache_file_lists()` stubs must init `CACHED_*_FILES=()` (SC2178).

## CI integration

Tests run on push, PR, manual dispatch. POSIX: `nix run ./src#test`. Windows: `bootstrap.ps1` → `test.ps1` (step 6 `windows-pester`). Pester lockfile-pinned.

## Validation checklist

- [ ] Nix tests: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`
- [ ] Flake: `cd src && nix flake check`
- [ ] Shell: `nix run ./src#check-sh`
- [ ] PS syntax: `pwsh -File scripts/check-pwsh.ps1 -SkipStep PSSA`
- [ ] PS PSSA: `pwsh -File scripts/check-pwsh.ps1 -SkipStep Syntax -Settings scripts/test-PSScriptAnalyzerSettings.psd1`
- [ ] Pester: `pwsh -File scripts/test.ps1 --skip-steps=nix-tests,system-config-build`
