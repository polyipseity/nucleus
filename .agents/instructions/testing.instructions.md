---
description: "Use when implementing new features, modules, or changes that require test coverage. Mandates TDD practices for Nix and Windows DSC configurations. Covers test structure, CI integration, and validation patterns."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Testing guidelines

Every feature addition or breaking change requires tests. Layout mirrors `src/` (see `AGENTS.md`). Nix-based tests run on macOS/NixOS, Pester on Windows.

## Fail-fast convention

`check.sh` / `check.ps1` accumulate all failures so one run reports everything. `test.sh` / `test.ps1` exit on the first failure to keep CI quiet and fast. Both accept `--fail-fast` / `--no-fail-fast`. prek hooks use the defaults; CI always passes `--no-fail-fast`.

## Quick start

```bash
# Nix tests
nix-instantiate --eval --strict tests/modules/package-parity-tests.nix
nix-instantiate --eval --strict tests/modules/posix-module-imports-tests.nix
nix-instantiate --eval --strict -A summary tests/modules/vm-setup-manifest-tests.nix  # attr is `summary`
cd src && nix flake check
```

```powershell
# Windows tests (admin required)
Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose
```

## Nix testing strategy

### Layer 1: Static evaluation

`nix flake check` evaluates every host config without building, catching syntax errors, unresolved imports, and mistyped options.

### Layer 2: Pure logic tests

Under `tests/modules/`, `tests/integration/`, `tests/hosts/`. Use `assert'` from `tests/lib.nix` and force the result with `builtins.seq (builtins.deepSeq <tests> null)` or `builtins.all`.

Forcing evaluation is mandatory: Nix is lazy, so a test file that only counts tests reports green with zero tests run. Prohibited: `success = true` with only `builtins.length` references, and the one-argument `builtins.seq (builtins.deepSeq <tests>)`, which forces nothing.

### No real-user test coupling

Tests must not reference a real `src/users/<username>/` directory. `default` is the exception: it is the production-managed baseline.

| Pattern | When |
| --- | --- |
| `tests/fixtures/user-registry/` + `test-user` + `--repo-root` | Registry, cloud-drives, symlinks, any discovered-user test |
| `src/users/default/` reads | Baseline template content only |
| Temp-dir users (`alice`, `bob`) + `-RepoRoot` | Overlay resolution unit tests (ConfigHelpers) |
| Dynamic `primaryUser` from `load-user-registry.sh` | Integration tests evaluating the live repo |

Prohibited: hardcoded usernames matching production dirs, production data copied into assertions, test-only users created under production `src/users/`.

Fixtures live in `tests/fixtures/user-registry/src/users/` (`test-user`), with constants in `tests/fixtures/default.nix` and helpers in `tests/scripts/user-registry-fixture.sh`. The fixture `default` symlinks to the live `src/users/default`, so edits there are production edits.

### Layer 3: Module import wiring

`tests/modules/posix-module-imports-tests.nix` enumerates `src/modules/posix/` and compares it against the aggregator, so a module dropped from `src/modules/posix/default.nix` fails the suite. Nothing else can catch that class: an unreferenced module is valid Nix, and neither `nix flake check` nor a rebuild warns. The same file also pins the module allowlist and the machine age-key path across its three spellings.

### Test troubleshooting

- macOS `std::regex` treats `\(` as a capturing group. Use `[(]`.
- `assert'` reports only the first failure. Swap in a recording no-op to find the rest.
- deadnix flags `let` bindings the return never forces. Remove the binding or force it with `deepSeq`; never suppress deadnix.
- After refactoring a template inline to `builtins.readFile`, tests must read the extracted file.

## Windows testing strategy (Pester)

`tests/platforms/Windows/modules/**/*.Tests.ps1`.

## Adding new tests

Contract-breaking change: add Nix logic or Pester tests. Bug fix: a reproducing case when the behavior is not obvious. Commit tests atomically with the implementation. Name them `tests/<area>/<topic>-tests.nix` and `tests/platforms/Windows/modules/<area>/<feature>.Tests.ps1`.

## Assertions must discriminate

An assertion on a value that cannot distinguish the outcomes it claims to test proves nothing. The rclone mount runner exits 0 on a running mount, a blocked one, a terminal failure, and an exhausted retry alike, so every `rc -eq 0` assertion over it passed regardless. The same shape hides in expectations derived from the host under test and in gates comparing two lists that are both empty.

Before writing an assertion, name the result that would make it fail. Assert that discriminating fact (attempt count, recorded state, resolved path), not the summary every path shares, then break the behavior and confirm the assertion fires.

## Anti-pattern: grep-only Nix tests

`builtins.readFile` plus `containsRegex` or `lib.hasInfix` is implementation-coupled: it breaks on reflow, renames, or comment edits and asserts no behavior.

Acceptable: proving a banned pattern is absent (`!containsRegex "pip install"`), validating annotation presence, matching expected error text in a failure test, and parsing shell scripts when nothing else works (add a `# WHY:` comment).

Unacceptable: asserting a function name, an import path, or a string literal exists in a source file. Convert those to behavioral tests that evaluate the module with fixture data and check output attributes.

## Test script gotchas

Test scripts only, never production code.

- `tests/scripts/check-steps/` are plain pwsh scripts with PASS/FAIL output. Pester discovers 0 tests, so run them directly and check the exit code. Test step 5 (`script-and-framework-tests`) wires them.
- `exit` is not catchable by `try/catch`; spawn a subprocess and read `$LASTEXITCODE` plus its output.
- `& script.ps1` does not set `$LASTEXITCODE`.
- Tests asserting `UNDEFINED` pass standalone but fail in-suite: `test-lib.ps1` defines `Write-ErrorMessage`/`Write-Message`.
- `test.ps1` fail-fast kills the process before the summary; debug with `--no-fail-fast`.
- `.sh` test comments carry no `__TOKEN__`-delimited names and no two fragments of the same-line regex. Review requirements only, nothing machine-parses them.
- A suite sourcing `tests/scripts/test-lib.sh` must end with `finish_tests`. It is the only sanctioned exit and the only emitter of the `# nucleus-tally` line test step 5 requires, so an early exit or a call in a branch that never runs is reported as `no tally`. The tally carries only `passed` and `failed`: a case that cannot run on this host asserts the host-correct expectation rather than skipping, and a missing prerequisite fails loudly through the library's `require_command`. `src/scripts/lib/lib.sh` also defines a `die`-based `require_command`, so a suite sourcing both libraries gets that one and surfaces the mistake as a missing tally.
- Run suites through the `nucleus-test` app, which provides `python3` with PyYAML. A bare shell must supply its own interpreter.
- `.sh` files with shebangs must be executable; `.ps1` stay 644. Libraries derive `REPO_ROOT` themselves. `cache_file_lists()` stubs must initialize `CACHED_*_FILES=()` (SC2178).

## CI integration

Push, PR, and manual runs. POSIX: `nix run ./src#test`. Windows: `bootstrap.ps1` then `test.ps1`.

## Validation checklist

- [ ] `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`
- [ ] `cd src && nix flake check`
- [ ] `nix run ./src#check`
- [ ] `pwsh -File scripts/check-pwsh.ps1 -OnlyStep PSSA`
- [ ] `pwsh -File scripts/check-pwsh.ps1 -OnlyStep Syntax -Settings scripts/test-PSScriptAnalyzerSettings.psd1`
- [ ] `pwsh -File scripts/test.ps1 --only-steps=nix-tests`
