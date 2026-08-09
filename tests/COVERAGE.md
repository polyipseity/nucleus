# Nucleus test coverage summary

## Overview

The suite validates configuration logic, module composition, package parity, shell entry scripts, and Windows source/contract tests. Layout mirrors `src/`: cross-host Nix tests in `tests/modules/` and `tests/integration/`; host tests in `tests/hosts/<Host>/`; platform tests in `tests/platforms/<Platform>/` (Windows Pester under `tests/platforms/Windows/modules/`).

## Pipelines

| Pipeline | Steps | Notes |
| -------- | ----- | ----- |
| `scripts/check.sh` / `check.ps1` | 14 check steps (after policy merge) | Shell entry-script validation moved to test step 5 |
| `scripts/test.sh` / `test.ps1` | 5 POSIX / 6 Windows | Step 5 auto-discovers `tests/scripts/**/*-tests.{sh,ps1}`; step 6 runs Pester on Windows |
| Nix eval | test step 1 | Includes nix-test-eval guard before parallel eval |

## Windows Pester

- Provisioned via `lockfile.json` (`pwsh.Pester`), `pwsh.nix` activation, and `Invoke-PowerShellModuleSetup` (bootstrap + apply).
- Preflight: `Assert-ToolAvailable Pester` in `test-lib.ps1` (separate from provisioning).
- CI: Windows job runs `bootstrap.ps1`, installs Nix for env-parity manifest materialization, then `test.ps1`.

## Metrics

| Metric | Before prune | After prune |
| ------ | ------------ | ----------- |
| Check steps | 18 | 14 |
| Test orchestrator | 5 POSIX / 6 Windows | 5 POSIX / 6 Windows |
| Nix test files | 23 | 23 |
| `tests/scripts` shell/ps1 tests | 19 | 20 (added `check-pwsh-tests.ps1`) |
| Windows Pester | 15 | 15 |

## Provisioning vs preflight

Provisioning installs tools; preflight verifies they exist before check/test runs. Repo-managed tools (Pester, PSScriptAnalyzer, `powershell-yaml`) still require preflight declaration. See `tooling-and-validation.instructions.md`.
