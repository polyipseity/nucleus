---
description: "Use when editing or adding functions/steps in src/scripts, scripts, or tests. Bans reading shared state from enclosing scope; state must flow through parameters or the step-runner context object."
name: "No Ambient Passing"
applyTo: "src/scripts/**, scripts/**, tests/**"
---

# No ambient passing of shared state

## Rule

No function or step may read state from enclosing scope (`$script:` in PowerShell, globals in bash, module-level vars in Python/TS) that was not passed as a parameter.
State must flow through the call signature.
The step-runner context object is the only carrier of runner-populated state.

## Step context contract

Check/test steps receive a context object as their first parameter:
- PowerShell: `$Context.<Field>` (a `[PSObject]` built by `step-runner.ps1`).
- Bash: `${ctx[...]}` (an associative array referenced via `local -n ctx="$1"`, built by `step-runner.sh`).

Steps read only from that context and their own `local` variables — never from ambient scope.
Step-private accumulators (counters, exit codes) must be `local` / `$local:`. Never write them to shared scope for other steps to read.

## Intentional exceptions

Documented required environment inputs (e.g. `REPO_ROOT`, `NUCLEUS_REPO_ROOT` in lib helpers) or external env vars (e.g. `PARALLEL_JOBS`) are not ambient passing of runner state.
Mark the exception with a `# WHY:` comment if non-obvious.

## Rationale

Ambient passing breaks under isolation (runspaces, subshells, strict scoping). PowerShell runspaces cannot inherit the caller's `$script:` scope, so steps reading `$script:`-scoped state either fail or corrupt the main session via concurrent access. Bash subshells copy globals, hiding the same defect. See `step-runner.instructions.md`, `programming-principles.instructions.md`, and `core-behavior.instructions.md`.
