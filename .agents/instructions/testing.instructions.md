---
description: "Use when changes need test coverage, or authoring a check or test that reads source text."
name: "Testing Guidelines"
applyTo: "tests/**, src/hosts/Windows/**/*.yml, src/platforms/Windows/modules/**/*.ps1, tests/scripts/**, src/scripts/checks/**, src/scripts/tests/**, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, .github/workflows/**"
---

# Testing guidelines

Every feature or breaking change needs tests; layout mirrors `src/`. Nix tests run on macOS and NixOS, Pester on Windows. `check.sh`/`check.ps1` accumulate failures, `test.sh`/`test.ps1` fail fast; both accept `--fail-fast`/`--no-fail-fast`, CI passes `--no-fail-fast`.

Nix tests must force evaluation with `builtins.seq (builtins.deepSeq <tests> null)` or `builtins.all`; counting-only tests are green with zero tests run. No test references a real production user; use `tests/fixtures/user-registry/` with `test-user`, `src/users/default/` only for baseline reads, temp users with `-RepoRoot`, or dynamic `primaryUser`. `posix-module-imports-tests.nix` catches dropped modules from `src/modules/posix/`.

Assertions must discriminate and be confirmed by breaking the behavior. A text-only check needs all four: no behavioral point, structural match, actionable failure, no duplicate enforcement. Test suites sourcing `test-lib.sh` end with `finish_tests`, which emits `# nucleus-tally`; missing tally fails. `exit` needs a subprocess, `& script.ps1` does not set `$LASTEXITCODE`, and run suites through `nucleus-test`.

Validation: `find tests/modules tests/integration tests/hosts -name '*.nix' -exec nix-instantiate --eval {} +`, `cd src && nix flake check`, `nix run ./src#check`, PSSA and Syntax check steps, and `pwsh -File scripts/test.ps1 --only-steps=nix-tests`. Details: `src/users/default/agents/skills/nucleus-platform-reference/references/testing.md`.
