# Nucleus test coverage summary

## Overview

The suite validates configuration logic, module composition, package parity, shell entry scripts, and Windows source/contract tests. Layout mirrors `src/`: cross-host Nix tests in `tests/modules/` and `tests/integration/`; host tests in `tests/hosts/<Host>/`; platform tests in `tests/platforms/<Platform>/` (Windows Pester under `tests/platforms/Windows/modules/`).

## Pipelines

| Pipeline | Steps | Notes |
| -------- | ----- | ----- |
| `scripts/check.sh` / `check.ps1` | 18 check steps | Migration guards and meta test steps removed |
| `scripts/test.sh` / `test.ps1` | 5 POSIX / 6 Windows | Step 6 runs pruned Pester suite on Windows |
| Nix eval | test step 1 | Includes nix-test-eval guard before parallel eval |

## Windows Pester

- Provisioned via `lockfile.json` (`pwsh.Pester`), `pwsh.nix` activation, and `Invoke-PowerShellModuleSetup` (bootstrap + apply).
- Preflight: `Assert-ToolAvailable Pester` in `test-lib.ps1` (separate from provisioning).
- CI: Windows job runs `bootstrap.ps1`, installs Nix for env-parity manifest materialization, then `test.ps1`.

## Metrics

| Metric | Before | After |
| ------ | ------ | ----- |
| Check steps | 27 | 18 |
| Test orchestrator | 5 | 5 POSIX / 6 Windows |
| Nix test files | 75 | 24 |
| `tests/scripts` shell tests | 64 | 18 |
| Windows Pester | 31 | 15 |

## Provisioning vs preflight

Provisioning installs tools; preflight verifies they exist before check/test runs. Repo-managed tools (Pester, PSScriptAnalyzer, `powershell-yaml`) still require preflight declaration. See `tool-availability.instructions.md`.
