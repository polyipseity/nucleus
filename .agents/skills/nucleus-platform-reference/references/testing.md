---
description: "Use when changes need test coverage, or authoring a check or test that reads source text."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, src/scripts/checks/**, src/scripts/tests/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Testing guidelines

Every feature addition or breaking change needs tests; layout mirrors `src/`. Nix tests run on macOS and NixOS, Pester on Windows. `check.sh` / `check.ps1` accumulate failures; `test.sh` / `test.ps1` exit on first. Both accept `--fail-fast` / `--no-fail-fast`; prek uses defaults, CI passes `--no-fail-fast`.

Commands: `nix-instantiate --eval --strict tests/modules/package-parity-tests.nix`, the same for `posix-module-imports-tests.nix`, `nix-instantiate --eval --strict -A summary tests/modules/vm-setup-manifest-tests.nix`, `cd src && nix flake check`, and `Invoke-Pester -Path tests/platforms/Windows/modules/ -Verbose`.

`nix flake check` evaluates hosts without building. Pure logic tests under `tests/modules/`, `tests/integration/`, `tests/hosts/` use `assert'` from `tests/lib.nix` and must be forced with `builtins.seq (builtins.deepSeq <tests> null)` or `builtins.all`. Lazy evaluation makes a counting-only test green with zero tests run. Prohibited: `success = true` with only `builtins.length`, and one-argument `builtins.seq (builtins.deepSeq <tests>)`.

No test references a real `src/users/<username>/`; `default` is the production baseline exception. Fixture path `tests/fixtures/user-registry/src/users/` with `test-user` and `--repo-root` covers registry, cloud, symlink, and discovered-user tests; `src/users/default/` reads only baseline templates; temp users (`alice`, `bob`) plus `-RepoRoot` cover overlay unit tests; dynamic `primaryUser` from `load-user-registry.sh` covers live integration. Never hardcode production usernames, copy production data into assertions, or create test users in production `src/users/`. Constants live in `tests/fixtures/default.nix`, helpers in `tests/scripts/user-registry-fixture.sh`; the fixture `default` symlinks to live `src/users/default`, so edits there are production edits.

`tests/modules/posix-module-imports-tests.nix` compares `src/modules/posix/` against its aggregator, catching dropped modules that flake check and rebuild miss. It also pins the module allowlist and age-key path across three spellings. Troubleshooting: macOS `std::regex` reads `\(` as a group, so use `[(]`; `assert'` reports one failure, so swap in a recording no-op; deadnix findings are real, remove or force them, never suppress; after extracting a template, tests read the extracted file.

Contract-breaking changes get Nix or Pester tests; non-obvious bug fixes get a reproducing case; tests land with implementation as `tests/<area>/<topic>-tests.nix` or `tests/platforms/Windows/modules/<area>/<feature>.Tests.ps1`.

An assertion must discriminate: name the result that would make it fail, assert that fact (attempt count, state, resolved path), then break the behavior and confirm failure. Expectations derived from the host under test and gates comparing two empty lists prove nothing.

## Text-only checks

Banned unless all four hold: no behavioral enforcement point exists; the match anchors to syntax, markers, or layout, not prose or formatting; failure names a defect; nothing else enforces the rule. A text check failing on formatting is deleted. Converting it to an executing test is second and only when behavior runs in the check environment. Name the four conditions in the change.

## Gotchas

`tests/scripts/check-steps/` are plain pwsh with PASS/FAIL; Pester discovers zero, so run them directly and check exit code (step 5 wires them). `exit` is not catchable by `try/catch`; spawn a subprocess and read `$LASTEXITCODE`. `& script.ps1` does not set `$LASTEXITCODE`. `UNDEFINED` assertions pass alone but fail in-suite because `test-lib.ps1` defines the writers. `test.ps1` fail-fast kills before summary; debug with `--no-fail-fast`. `.sh` test comments carry no `__TOKEN__` names and no two fragments of one same-line regex.

A suite sourcing `tests/scripts/test-lib.sh` must end with `finish_tests`: sole sanctioned exit and emitter of `# nucleus-tally`, which step 5 requires. Early or unreachable calls report `no tally`; the tally holds only `passed` and `failed`; a case that cannot run on the host asserts the host-correct expectation rather than skipping; missing prerequisites fail through `require_command`. `src/scripts/lib/lib.sh` also defines a `die`-based `require_command`, so sourcing both yields a missing tally. Run suites through `nucleus-test` for python3 with PyYAML. `.sh` with shebangs are executable, `.ps1` stay 644; libraries derive `REPO_ROOT`; `cache_file_lists()` stubs initialize `CACHED_*_FILES=()` (SC2178).

Push, PR, and manual runs: POSIX `nix run ./src#test`, Windows `bootstrap.ps1` then `test.ps1`.

Validation: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`; `cd src && nix flake check`; `nix run ./src#check`; `pwsh -File src/scripts/checks/check-pwsh.ps1 -OnlyStep PSSA`; the same with `-OnlyStep Syntax -Settings scripts/test-PSScriptAnalyzerSettings.psd1`; `pwsh -File scripts/test.ps1 --only-steps=nix-tests`.
