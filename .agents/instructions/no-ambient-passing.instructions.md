---
description: "Use when editing or adding functions/steps in src/scripts, scripts, or tests. Bans reading shared state from enclosing scope; state must flow through parameters or the step-runner context object."
name: "No Ambient Passing"
applyTo: "src/scripts/**, scripts/**, tests/**"
---

# No ambient passing of shared state

## Rule

No function or step may read shared state from enclosing scope (`$script:` in PowerShell, globals in bash, module-level vars in Python/TS) that was not passed as a parameter.
State must flow through the call signature.
The step-runner context object is the **only** sanctioned carrier of runner-populated shared state.

## Step context contract

Check/test steps receive a context object as their first parameter:
- PowerShell: `$Context.<Field>` (a `[PSObject]` built by `step-runner.ps1`).
- Bash: `${ctx[...]}` (an associative array referenced via `local -n ctx="$1"`, built by `step-runner.sh`).

Steps read only from that context and from their own `local` variables — never from ambient scope.
Step-private accumulators (counters, exit codes) must be `local` / `$local:`, never written to shared scope to be read back elsewhere.

## Intentional exceptions

A documented required environment input (e.g. `REPO_ROOT`, `NUCLEUS_REPO_ROOT` in lib helpers) or an external env var (e.g. `PARALLEL_JOBS`) is not ambient passing of runner state.
Mark the exception with a `# WHY:` comment if non-obvious.

## Rationale

Ambient passing silently breaks under isolation (runspaces, subshells, strict scoping) and hides data flow.
This was the root cause behind the step-runner context contract: PowerShell runspaces cannot inherit the caller's `$script:` scope, so steps that read `$script:`-scoped shared state either fail outright or corrupt the main session via concurrent access.
Bash subshells happen to copy globals, masking the same latent defect.
See `step-runner.instructions.md` (framework contract), `programming-principles.instructions.md` (explicit boundaries), and `core-behavior.instructions.md` (immutable-by-default, no fallbacks).
