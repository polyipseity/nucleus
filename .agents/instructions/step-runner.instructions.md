---
description: "Use when implementing or modifying the step-runner framework used by the check and test pipelines. Covers step registration, declared applicability (platform, mode, requires), the --only-steps selector, run-state rendering, PS1 parallelism, and step 7 $schema enforcement."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework interface specification

`step-runner.sh` and `step-runner.ps1` are one interface with two implementations. A rule stated here applies to both unless it names a platform.

## Registration

`register_step(id, name, func)` defaults to `any`/`any`/`none`; the 6-argument form declares applicability; the 4-argument form takes an explicit number and exists only for unit tests. Ids are unique, kebab-case, digit-free, and take their number from the `NN-` filename prefix. Tokens are `platform`: `any|posix|windows` (`posix` covers macOS and NixOS), `mode`: `any|full|scoped`, and `requires`: `none|nix|network|sops-machine-key|deployed-host`. An unknown token, a duplicate number, or an underivable number is a registration-time hard error. PowerShell spells it `Register-Step -Id -Name -Action [-Number] [-Platform] [-Mode] [-Requires]`.

## Run state

The runner, never the step, decides whether a step runs, and it reports every skip in the header:

- id excluded by `--only-steps` → `not-selected`, checked first so it is never reported as not applicable
- `posix` on Windows or `windows` on POSIX → `not applicable (platform: <token>)`
- `scoped` without positional args, `full` with them → `not applicable (mode: <token>)`
- missing prerequisite → `not applicable (requires: <token>)`

A step that does not run never affects the exit code (0 pass, 1 fail) and never prints "passed" or "no issues found".

`--only-steps=id1,id2` is mandatory-`=` and comma-separated; whitespace is trimmed, duplicates collapse, an empty value is a no-op, and the last flag wins. An unregistered id is a hard error listing the known ids, because a typo would otherwise narrow the run to nothing and report success. Selection is applied before the platform, mode, and requires checks, and it does not affect `--fail-fast`.

Step 01 runs `treefmt` in place, so a pipeline can reformat files silently: run `git status --short` afterwards and commit the result as a `style(...)` change. Test step 04 declares `requires sops-machine-key` and Windows has no counterpart for it.

## PowerShell dispatch

`Invoke-StepPipeline` runs steps in waves capped at `PARALLEL_JOBS` (CPU count by default), one `[PowerShell]::Create()` runspace per step driven with `BeginInvoke`, and replays results in step-number order. Not `RunspacePool` or `Start-Job`, because those are the constructs that make runspace state unpredictable for the steps below.

## Step 7 `$schema` enforcement

Nucleus-owned JSON and YAML requires an inline `$schema` pointing at a co-located schema file. External formats use their published `$schema` when one exists and never a hand-rolled one. The exception list is the A8 row in `allow-and-deny-lists.instructions.md`; a missing, non-string, or dangling `$schema` is a per-file error, and the step fails if any file errored. POSIX and Windows behave identically.

## Adding or renumbering steps

Step numbers come from the `NN-` prefix of `src/scripts/checks/check-steps/<nn>-*.{sh,ps1}`. A number must describe what the step does, so opening a new group means renumbering. Renaming means moving the step and its test together and sweeping every reference: `TEST_FILE`/`$testFile`, `# shellcheck source=`, `repository-policy.awk`, prose "step N", and generator or installer comments. Do the rename in one commit before creating the new pair. Test-pipeline steps follow the same rules; shell validation lives in test step 5, not in the check pipeline.

## No ambient shared state

A step reads its context parameter and its own locals, nothing else. The context is the first parameter: `$Context.<Field>` in PowerShell, `${ctx[...]}` in Bash via `local -n ctx="$1"`. Private accumulators stay out of shared scope. Documented env inputs are the exception (`REPO_ROOT`, `NUCLEUS_REPO_ROOT`, `PARALLEL_JOBS`), each needing a `# WHY:` when it is not self-evident.

PowerShell runspaces cannot inherit `$script:` state, so a read either fails or races; Bash subshells copy globals silently, so a write leaks into the parent. The context object is the only channel.

## Output color

F2 and F4 palette via `_nuc_color_init` (`src/scripts/lib/lib.sh`) and `$PSStyle` (`Format-NucleusOutput.psm1`): `notice` bold blue, `[step NN]` dim, green check, red cross, yellow en dash for not applicable or not selected, dim labels. Captured files stay plain. Raw ANSI, `tput`, and `echo -e` are banned outside the shared helpers (check step 12). Gating: `output-handling.instructions.md`.
