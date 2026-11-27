---
description: "Use when implementing or modifying the check and test step-runner framework."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework

`step-runner.sh` and `step-runner.ps1` are one interface with two implementations; a rule applies to both unless it names a platform.

## Registration and run state

`register_step(id, name, func)` defaults to `any`/`any`/`none`; the 6-argument form declares applicability, the 4-argument form takes an explicit number for tests only. Ids are unique, kebab-case, digit-free, numbered from the `NN-` filename prefix. Tokens: platform `any|posix|windows` (`posix` covers macOS and NixOS), mode `any|full|scoped`, requires `none|nix|network|sops-machine-key|deployed-host`. Unknown token, duplicate number, or underivable number is a registration hard error. PowerShell: `Register-Step -Id -Name -Action [-Number] [-Platform] [-Mode] [-Requires]`.

The runner decides and reports every skip: `--only-steps` exclusion → `not-selected` (checked first), wrong platform → `not applicable (platform: <token>)`, wrong mode → `not applicable (mode: <token>)`, missing prerequisite → `not applicable (requires: <token>)`. A skipped step never affects exit code or prints passed/no-issues.

`--only-steps=id1,id2` requires `=`, is comma-separated, trims whitespace, collapses duplicates, treats empty as no-op, and last flag wins. An unregistered id is a hard error listing known ids. Selection runs before platform/mode/requires and does not affect `--fail-fast`. Step 01 (`treefmt`) reformats in place, so check `git status --short` afterward and commit `style(...)` changes. Test step 04 requires `sops-machine-key`; Windows has no counterpart.

## Dispatch

Both runners use a work queue capped at `PARALLEL_JOBS` (CPU count default): free slots launch pending steps immediately and release on completion. `[k/N] step ... started` uses launch order; each step prints `step <n> finished (<dur>)`. The runner prints `step <n> still running (<dur>)` every `NUCLEUS_STEP_PROGRESS_INTERVAL` seconds (`15` default, `0` disables, non-numeric/negative hard-error before launch).

`NUCLEUS_STEP_TIMEOUT` bounds each step in whole seconds (`600` default, `0` disables, non-numeric hard-error). Expiry writes exit `124` and appends `step <n> exceeded NUCLEUS_STEP_TIMEOUT=<seconds>s` to captured output, then fails. POSIX polls wrappers on a 0.25 s tick to keep bash 5.1. PowerShell uses one `[PowerShell]::Create()` runspace per step with `BeginInvoke` and `WaitAny` over async handles, not `RunspacePool` or `Start-Job`.

`--fail-fast` stops new launches, drains in-flight steps, reports failures in launch order, exits 1. Output files, `=== [NN] name ===` headers, and `sum of steps`/`wall clock` lines stay unchanged. A throwing PowerShell runspace records exit 1 plus exception in its replay file; the abort path prints one message before exit.

## Step 7 schema and authoring

Nucleus JSON/YAML needs an inline `$schema` pointing to a co-located schema; external formats use published schemas. The exception list is row A8 in `allow-and-deny-lists.instructions.md`. Missing, non-string, or dangling `$schema` is a per-file error and fails the step identically on both platforms.

Step numbers come from `NN-` prefixes in `src/scripts/checks/check-steps/<nn>-*.{sh,ps1}`; a number must describe the step, so opening a group means renumbering. Rename step and test together and sweep `TEST_FILE`/`$testFile`, `# shellcheck source=`, `repository-policy.awk`, prose "step N", and generator/installer comments in one commit. Test steps follow the same rules; shell validation belongs in test step 5.

## Context and color

A step reads only its context parameter and locals. Context is first parameter: `$Context.<Field>` in PowerShell, `${ctx[...]}` with `local -n ctx="$1"` in bash. Private accumulators stay private. Documented env exceptions (`REPO_ROOT`, `NUCLEUS_REPO_ROOT`, `PARALLEL_JOBS`, `NUCLEUS_STEP_PROGRESS_INTERVAL`, `NUCLEUS_STEP_TIMEOUT`) need `# WHY:` when not self-evident. PowerShell runspaces cannot inherit `$script:` state; bash subshells copy globals silently, so context is the only channel.

Color uses F2/F4 palette via `_nuc_color_init` (`lib.sh`) and `$PSStyle` (`Format-NucleusOutput.psm1`): notice bold blue, step marker dim, green check, red cross, yellow en dash for not applicable or not selected, dim labels. Captured files stay plain. Raw ANSI, `tput`, `echo -e`, and backtick-e escapes are banned outside helpers (step 12); gating is in `output-handling.instructions.md`.
