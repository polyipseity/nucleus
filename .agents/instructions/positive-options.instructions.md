---
description: "Use when adding CLI options, script variables, or config knobs across the nucleus repo. Enforces --XXX/--no-XXX flag-pair naming to avoid double negation."
name: "Positive Options Policy"
applyTo: "scripts/**, src/scripts/**, src/**/*.ps1, src/hosts/Windows/**/*.yml"
---

Use `--XXX`/`--no-XXX` flag pairs for CLI options and positive variable names
for scripts and config knobs. Every feature must support both `--XXX` and
`--no-XXX` regardless of its default state.

Rule table:

| Aspect              | Convention                                          |
| ------------------- | --------------------------------------------------- |
| Shell variable      | `ai_sync=true` (positive, no prefix)                |
| Conditional check   | `if [ "$ai_sync" = false ]` or `if [ "$ai_sync" = true ]` |
| POSIX CLI flag      | `--ai-sync` (enables) / `--no-ai-sync` (disables)   |
| PowerShell param    | `[switch]$AISync` + `[switch]$NoAISync`             |
| PowerShell call     | `-AISync` (enables) / `-NoAISync` (disables)        |

Rules:

1. Every feature with a boolean CLI flag MUST support both `--XXX` and
   `--no-XXX` (or PowerShell equivalent: `-XXX` and `-NoXXX`).
2. Shell variables MUST use bare positive names without prefixes:
   - `ai_sync` ✓ (not `do_ai_sync`)
   - `replica_sync` ✓ (not `with_replica_sync`)
   - `vm_setup` ✓ (not `with_vm_setup`)
   - `secret_health` ✓ (not `do_secret_health`)
3. PowerShell internal variables MUST use `$noXXX` (lowercase) for the local
   copy and `$NoXXX` (PascalCase) for the param variable.
4. Do not prefix with `do_`, `with_`, or any other semantic qualifier. The
   variable name itself is the boolean.
