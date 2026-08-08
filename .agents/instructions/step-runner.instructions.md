---
description: "Use when implementing or modifying the step-runner framework used by the check and test pipelines. Covers step registration, --skip-steps semantics, removed flags, skip message format, PS1 parallelism, and step 8 $schema enforcement."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**"
---

# Step-runner framework interface specification

This document is the canonical contract for the step-runner framework used by the check and test pipelines. Both POSIX (`step-runner.sh`) and Windows/PowerShell (`step-runner.ps1`) implementations MUST conform to this spec.

## Spec A: Step ID registration

```
register_step(id: str, number: int, name: str, func: Function)
  id:      Non-empty string, no ASCII digits (0-9). Must be unique among all registered steps.
           Recommended: kebab-case, all lowercase, hyphens for word separators.
  number:  Positive integer. Must be unique. Must match the 2-digit prefix of the source file.
  name:    Human-readable display name. Used in output headers.
  func:    Function to call when step executes. Called with args: (has_args, repo_root, ...files).

  Validation errors (hard failure, stops script):
    - id contains a digit char  → "Step ID '<id>' contains forbidden digit"
    - id is empty               → "Step ID must not be empty"
    - id duplicates existing    → "Duplicate step ID '<id>'"
    - number duplicates         → "Duplicate step number <number>"
    - func is not callable      → "Step <number> function is not callable"

  Effect: Appends (id, number, name, func) to the step arrays _STEP_IDS, _STEP_NUMBERS,
          _STEP_NAMES, _STEP_FUNCS (POSIX); $script:StepIds, $script:StepNumbers, etc. (PS1).

  Cross-platform equivalence:
    - Same validation rules
    - Same error messages (same text — executed in different shells)
    - Same side effects on internal state
```

## Spec B: `--skip-steps` flag

```
parse_args flag: --skip-steps=<comma-separated-ids>

  Single form only: --skip-steps=id1,id2,id3
    --skip-steps followed by space is NOT supported (to avoid ambiguity with positional file args).
    = sign is mandatory.

  Value: Comma-separated list of step IDs. Whitespace around commas is stripped.
    Empty value (--skip-steps=) is valid — means "skip nothing", no-op.

  Effect:
    - Populates SKIP_STEPS array (POSIX) / $script:SkipSteps array (PS1)
    - Each entry is an individual ID (after splitting by comma)

  Execution-time behavior (run_all_steps / Invoke-StepPipeline):
    For each step before execution:
      if step.id is in SKIP_STEPS:
        output: "==== <number>: <name> ==== SKIPPED (--skip-steps: <id>)"
        skip execution, mark step as skipped (exit code 2 — not a failure)
      else:
        execute normally

  Error cases:
    - Unknown ID in --skip-steps: NOT an error (allow future-proofing — IDs may be added later).
      Unknown IDs are silently ignored. (Rationale: forward compatibility.)
    - Duplicate ID in --skip-steps: silently deduplicate.
    - --skip-steps given multiple times: last value wins (no accumulation).

  Interaction with --fail-fast:
    - Skipped steps do not trigger fail-fast (they're not failures).
    - Non-skipped steps that fail still trigger fail-fast as normal.

  Interaction with --scoped:
    - Steps that already skip due to --scoped (no relevant files) still skip — the --skip-steps
      skip message takes priority if both conditions apply.

  Cross-platform equivalence:
    - Same parsing rules (= sign mandatory)
    - Same skip message format (identical text)
    - Same deduplication behavior
    - Same interaction with --fail-fast
    - Same forward-compatible unknown-ID handling
```

## Spec C: `--format` removal (post-removal behavior)

```
Step 01 (code-formatting) behavior:
  Always runs `treefmt` to format all source files in-place.
  treefmt is invoked without --fail-on-change.
  No format-vs-validate dual mode exists anymore.
  Step 01 is skipped only if treefmt itself isn't available.

  Cross-platform:
    - POSIX: runs treefmt binary directly
    - PS1: runs treefmt binary directly (POSIX step covered; PS1 step matches POSIX step)
    - Both produce the same output message format.
```

## Spec D: `--skip-system-build` removal (post-removal behavior)

```
Test step 04 (system-config-build):
  - POSIX: always runs on supported platforms (macOS, Linux); skips only with platform message
    "==== 4: System config build ==== SKIPPED (not a supported OS for system config build)"
  - PS1: always skips with "==== 4: System config build ==== SKIPPED (system config build is POSIX-only)"
  - A skipped step exits with code 2 (not a failure).
  - No flag controls whether step runs.
  - The --skip-system-build flag no longer exists.
```

## Spec E: PS1 parallelism

```
Invoke-StepPipeline behavior:
  - Same wave-based parallelism as POSIX step-runner.sh.
  - Wave grouping: steps are assigned to waves arbitrarily (all steps are independent).
    Currently: single wave containing all steps (same as POSIX — all steps dispatch in parallel).
  - PARALLEL_JOBS env var controls max concurrent jobs. Default: number of logical processors.
  - Parallel dispatch mechanism: RunspacePool (preferred — better performance, no temp files)
    Fallback: Start-Job + file-based exit code (mirrors POSIX wave pattern).
  - Output ordering: Steps' output is captured per-step and printed in step-number order,
    NOT in completion order. This matches POSIX behavior where aggregation prints in order.

  Error aggregation:
    - Each step's exit code is captured independently.
    - After all waves complete, overall exit code = max of all step exit codes (same as POSIX).
    - Fail-fast: if any step fails, stop after current wave, exit.

  Compatible with --skip-steps: skipped steps are excluded from parallelism (not dispatched).

  Cross-platform equivalence:
    - Same wave structure
    - Same output ordering (step-number, not completion)
    - Same error aggregation (max exit code)
    - Same fail-fast boundary (end of wave, not mid-wave)
```

## Spec F: Silent skip elimination

```
Every step that chooses NOT to run (for any reason — empty file list, platform mismatch,
missing tool) MUST output an explicit skip message with the pattern:

  "==== <number>: <name> ==== SKIPPED (<reason>)"

The <reason> must be a concise, human-readable explanation. Examples:
  - "no Nix files to check"
  - "no PowerShell files to check (scoped mode)"
  - "Nix not available on Windows"
  - "POSIX-only test suite"
  - "nixf-tidy not available on Windows"

Rules:
  - The step header (==== N: Name ====) must appear in ALL cases, including skip.
  - A skipped step is NOT a failure (exit code 2 — rendered as SKIP in the results table).
  - A skipped step MUST NOT say "passed" or "no issues found" — that implies it ran.
  - Every skip MUST go through the single canonical skip path (the skip check in the
    step function body), not via silent early-return or conditional execution that
    produces no output.

Cross-platform equivalence:
  - Same format for skip messages
  - Same reasons for skips (where applicable — some reasons are inherently platform-specific)
  - A step that skips on POSIX for a platform reason must also skip on PS1 (opposite direction)
  - No step on either platform says "passed" when it didn't run any checks
```

## Check step groups

| Group | Steps | IDs |
| ----- | ----- | --- |
| Format and lint | 01–03 | `code-formatting`, `powershell-lint` (syntax only; `-SkipStep PSSA`), `packer-validate` |
| Nix | 04–05 | `nix-flake-eval`, `nix-lint` |
| Data and schema | 06–10 | `lockfile-validation`, `locked-dsc-validation`, `schema-validation`, `service-registry`, `yaml-structural` |
| Repository policy | 11–14 | `package-manager-enforcement`, `suppression-audit`, `online-determinism`, `repository-policy` |

Shell entry-script validation (`script-validation-tests.sh`) runs in test step 5 (`script-and-framework-tests`), not in the check pipeline.

## Spec G: Step 8 `$schema` enforcement

```
Step 8 validation rules:
  For every JSON and YAML file in scope (except exceptions):

  1. `$schema` presence check:
     IF file lacks a `$schema` key
     AND file is not in EXCEPTION_LIST
     → ERROR "Missing $schema in <filepath>"
     (Continue checking other files — don't stop at first error)

  2. `$schema` validity check:
     IF file has a `$schema` that is a relative file path (not a URL/URI)
     AND the referenced file does not exist relative to the file's directory
     → ERROR "Schema file not found: '<schema_path>' (referenced from <filepath>)"

  3. `$schema` format check:
     IF `$schema` is present but empty or not a string
     → ERROR "Invalid $schema in <filepath>: must be a non-empty string"

  EXCEPTION_LIST (files that never need $schema):
    - *.schema.json files (they ARE schema files)
    - vendor/** (vendored third-party code)
    - secrets/** (generated/managed, not human-authored configs)
    - .github/workflows/*.yml, .github/dependabot.yml (use --builtin-schema for validation; globs are *-prefixed to match find's ./ prefix)
    - .gitignore, .gitkeep, package.json (infrastructure / well-known standard files)
    - opencode.jsonc (already has embedded $schema, checked by built-in schema)
    - App-owned config formats with no published JSON schema:
      - src/modules/configs/vscode/*.json (vscode:// schema URIs are not fetchable by check-jsonschema)
      - src/modules/configs/iterm2/DynamicProfiles/*.json
      - src/modules/configs/obsidian/*.json
      - src/modules/configs/qtpass/*.json
      - src/modules/configs/camilladsp/**, src/modules/configs/camillagui-backend/**
      - src/users/default/agents/skills/*/_meta.json (ClawHub skill metadata, generated/managed)
      - src/modules/ai/litellm-config.yml
      - .sops.yaml
    (Registered in .agents/instructions/allow-and-deny-lists.instructions.md)

  Error aggregation:
    - All errors are collected (non-fatal per-file).
    - After all files checked, if any errors found: step fails.
    - Total error count printed: "ERROR: <N> file(s) missing or invalid $schema"

  Cross-platform equivalence:
    - Same rules
    - Same exception list
    - Same error message format
    - Same aggregation (collect all, then report)
```

## Related instruction files

- `testing.instructions.md` — Test structure, CI integration, and validation patterns for the test pipeline.
- `tooling-and-validation.instructions.md` — Repository tooling, build commands, and validation hooks.
- `allow-and-deny-lists.instructions.md` — Step 8 EXCEPTION_LIST registry and exclude-list policy.
