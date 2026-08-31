---
description: "Use when implementing or modifying the step-runner framework used by the check and test pipelines. Covers step registration, --skip-steps semantics, removed flags, skip message format, PS1 parallelism, and step 7 $schema enforcement."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework interface specification

Canonical contract for the step-runner framework. Both POSIX (`step-runner.sh`) and Windows/PowerShell (`step-runner.ps1`) implementations MUST conform.

## Spec A: Step ID registration

```text
register_step(id: str, name: str, func: Function)                # 3-arg: number derived from NN- prefix
register_step(id: str, number: int, name: str, func: Function)   # 4-arg: explicit number (unit tests only)
  id:      Non-empty string, no ASCII digits (0-9). Unique among all registered steps.
           Recommended: kebab-case, all lowercase, hyphens for word separators.
  number:  Positive integer. Unique. Derived from the 2-digit prefix of the registering file's name;
           explicit override allowed in unit tests only.
  name:    Human-readable display name. Used in output headers.
  func:    Called with args: (has_args, repo_root, ...files).

  Number derivation: the 3-arg form derives the number from the registering file's NN- filename
  prefix (2-digit prefix required; registration fails with "cannot derive step number" if missing).
  The 4-arg form overrides the number explicitly and is allowed ONLY in unit tests
  (tests/scripts/step-runner-unit-tests.sh). PS1 equivalent: Register-Step -Number defaults to 0
  (derive); explicit -Number allowed only in unit tests
  (tests/scripts/step-runner-unit-tests.ps1).

  Validation errors (hard failure, stops script):
    - id contains a digit char  → "Step ID '<id>' contains forbidden digit"
    - id is empty               → "Step ID must not be empty"
    - id duplicates existing    → "Duplicate step ID '<id>'"
    - number duplicates         → "Duplicate step number <number>"

  Effect: Appends (id, number, name, func) to the step arrays _STEP_IDS, _STEP_NUMBERS,
          _STEP_NAMES, _STEP_FUNCS (POSIX); $script:StepIds, $script:StepNumbers, etc. (PS1).

  Cross-platform: same validation rules, same error messages, same side effects on internal state.
```

## Spec B: `--skip-steps` flag

```text
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
        output: "=== [<number>] <name> === SKIPPED (--skip-steps: <id>)"
        skip execution, mark step as skipped (exit code 2 — not a failure)
      else:
        execute normally

  Error cases:
    - Unknown ID: NOT an error (forward compatibility — IDs may be added later). Silently ignored.
    - Duplicate ID: silently deduplicate.
    - --skip-steps given multiple times: last value wins (no accumulation).

  Interaction with --fail-fast:
    - Skipped steps do not trigger fail-fast (not failures).
    - Non-skipped steps that fail still trigger fail-fast.

  Interaction with --scoped:
    - Steps that already skip due to --scoped (no relevant files) still skip — the --skip-steps
      skip message takes priority if both conditions apply.

  Cross-platform: same parsing rules, skip message format, deduplication, --fail-fast interaction,
  and forward-compatible unknown-ID handling.
```

## Spec C: `--format` removal (post-removal behavior)

```text
Step 01 (code-formatting) behavior:
  Always runs `treefmt` to format all source files in-place.
  treefmt is invoked without --fail-on-change.
  No format-vs-validate dual mode exists anymore.
  Step 01 is skipped only if treefmt itself isn't available.

  Write-mode consequence: check.sh/test.sh silently reformat the working tree
  and still exit 0, so a committed file can be nonconformant while pipelines
  stay green. Run `git status --short` after a pipeline run and commit any
  treefmt-rewritten files as `style(...)` fixes; run `treefmt` (write mode) on
  changed files before committing so committed state is conformant.

  Cross-platform:
    - POSIX: runs treefmt binary directly, plus Darwin workflow supplements and check-packer --validate-only
    - PS1: runs native formatter/linter CLIs in treefmt-equivalent order (shfmt, yamllint, taplo, packer fmt, actionlint, pinact, zizmor, check-packer --validate-only)
    - Both produce the same output message format.
```

## Spec D: `--skip-system-build` removal (post-removal behavior)

```text
Test step 04 (system-config-build):
  - POSIX: always runs on supported platforms (macOS, Linux); skips only with platform message
    "=== [4] System config build === SKIPPED (unsupported host <host>)" (number derived from the 04- prefix)
  - PS1: always skips with "=== [4] System config build === SKIPPED (POSIX-only test suite)"
  - A skipped step exits with code 2 (not a failure).
  - No flag controls whether step runs.
```

## Spec E: PS1 parallelism

```text
Invoke-StepPipeline behavior:
  - Same wave-based parallelism as POSIX step-runner.sh.
  - Steps dispatch in waves capped at PARALLEL_JOBS concurrent steps (default: logical processor count).
  - PARALLEL_JOBS env var controls max concurrent jobs per wave.
  - Parallel dispatch mechanism: one PowerShell instance per step via
    [System.Management.Automation.PowerShell]::Create() + BeginInvoke() (one runspace
    per step), dispatched in waves capped at PARALLEL_JOBS; each step's stdout, exit
    code, and timing are captured to per-step files (step-N.out / step-N.exit /
    step-N.time) under a wave temp dir, mirroring the POSIX wave pattern. No
    RunspacePool, no Start-Job.
  - Live output: each step line is prefixed [step NN] on stderr during execution; ordered
    unprefixed replay still appears in aggregate_results / Format-StepSummary.
  - Output ordering: Steps' output is captured per-step and printed in step-number order,
    not completion order. Matches POSIX behavior.
  - Timing summary reports sum of per-step duration and wall-clock duration as decimal
    seconds (`%.3f s`, e.g. `4.127 s`). Internal storage remains integer milliseconds
    (`step-N.time`, `pipeline.wall_ms`). POSIX measurement uses sub-second clocks on all
    supported OSes (`$EPOCHREALTIME`, perl Time::HiRes on Darwin, GNU `date +%s%3N` on Linux).

  Error aggregation:
    - Each step's exit code is captured independently.
    - After all waves complete, overall exit code = max of all step exit codes (same as POSIX).
    - Fail-fast: if any step fails, stop after current wave, exit.

  Compatible with --skip-steps: skipped steps are excluded from parallelism.

  Cross-platform: same wave structure, output ordering (step-number), error aggregation (max
  exit code), and fail-fast boundary (end of wave, not mid-wave).
```

### Output color

Live console chrome follows the F2/F4 palette via the shared color helpers — POSIX `_nuc_color_init` in `src/scripts/lib/lib.sh`, PS1 `$PSStyle` escapes embedded by `Format-NucleusOutput.psm1` — never raw ANSI, `tput`, or `echo -e` (check step 14).

- F1 message lines: the `notice` level renders bold blue; message-body semantic coloring (URLs underline-cyan, single-quoted spans blue) applies inside step output.
- Step chrome (F2): `[step NN]` marker is dim, content default.
- Results table (F4): glyphs ✓ green / ✗ red / SKIP yellow / ⊘ yellow (test-lib), labels dim.
- Captured step files and skip messages are plain: color is console-only, capture files hold no escape sequences.
- Colors are gated by NO_COLOR / FORCE_COLOR / tty detection per the console color spec in `logging.instructions.md`.

## Spec F: Silent skip elimination

```text
Every step that chooses NOT to run (for any reason — empty file list, platform mismatch,
missing tool) MUST output an explicit skip message:

  "=== [<number>] <name> === SKIPPED (<reason>)"

The <reason> must be a concise, human-readable explanation. Examples:
  - "no Nix files to check"
  - "no PowerShell files to check (scoped mode)"
  - "Nix not available on Windows"
  - "POSIX-only test suite"
  - "nixf-tidy not available on Windows"

Rules:
  - Every runtime self-skip MUST go through the shared skip_step helper (F3 form) rather than
    printing a bare literal; the runner's own --skip-steps path already emits the same F3 form
    via _run_skipped_step.
  - A skipped step is NOT a failure (exit code 2 — rendered as SKIP in the results table).
  - A skipped step MUST NOT say "passed" or "no issues found" — that implies it ran.
  - Every skip MUST go through the single canonical skip path (the skip check in the
    step function body), not via silent early-return or conditional execution.

Cross-platform: same skip message format, same reasons (where applicable — some are platform-
specific), no step says "passed" when it didn't run any checks.
```

## Check step groups

| Group | Steps | IDs |
| ----- | ----- | --- |
| Format and lint | 01–02 | `code-formatting` (treefmt on POSIX; native CLIs on Windows), `powershell-lint` (syntax only; `-SkipStep PSSA`) |
| Nix | 03–04 | `nix-flake-eval`, `nix-lint` |
| Data and schema | 05–10 | `lockfile-validation`, `locked-dsc-validation`, `schema-validation`, `service-registry`, `yaml-structural`, `completions-fresh` |
| Repository policy | 11–14 | `package-manager-enforcement`, `suppression-audit`, `online-determinism`, `repository-policy` |

## Adding or renumbering check steps

Step numbers derive from the `NN-` filename prefix of `src/scripts/checks/check-steps/<nn>-*.{sh,ps1}` (and `src/scripts/tests/test-steps/` for the test pipeline) at registration; step IDs are explicit digit-free kebab-case strings decoupled from numbers. Renumbering is a filename change plus a reference sweep — moved step files need no internal edits. The `tests/scripts/check-steps/<nn>-*-tests.{sh,ps1}` pairs hard-code their target step's filename (`TEST_FILE` / `$testFile` and `# shellcheck source=` comments), and prose "step N" references appear across `.agents/instructions/` and step-adjacent comments (`repository-policy.awk`, generator/installer headers), so every reference must move with the file in the same change.

- **No blind appending.** Never create a new step as the next unused number (`NN+1`) merely because it is next; a step number must reflect the step's function and group.
- **Group first, number second.** Before creating a new step, classify it into one of the groups above. If it fits an existing group, its number must land inside that group's range. A new group requires explicit justification and renumbering.
- **Rename first, then create.** When the target slot is occupied: (a) `git mv` the affected check-step pairs (`src/scripts/checks/check-steps/<nn>-*.{sh,ps1}`) and their test pairs (`tests/scripts/check-steps/<nn>-*-tests.{sh,ps1}`) to make room; (b) update every hard-coded reference in the same change — `TEST_FILE` / `$testFile` paths, `# shellcheck source=` comments, prose "step N" mentions across `.agents/instructions/`, `repository-policy.awk`, generator/installer comments, and the groups table; (c) create the new step pair and its test pair; (d) land all renames and the new step in ONE atomic commit.
- **Test-pipeline steps** (`src/scripts/tests/test-steps/`): same principles — place new test steps near their functional kin, renumber first when inserting, never blind-append.

Shell entry-script validation (`script-validation-tests.sh`) runs in test step 5 (`script-and-framework-tests`), not in the check pipeline. Step 5 runs priority framework suites serially, then parallelizes remaining `tests/scripts/**/*-tests.*` suites with ordered output replay; `nucleus-apps-smoke-tests.sh` runs under `nucleus_nix_locked` on POSIX.

## Spec G: Step 7 `$schema` enforcement

```text
Step 7 validation rules:
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
      - */users/*/vscode/*.json (vscode:// schema URIs are not fetchable by check-jsonschema)
      - */users/*/cursor/*.json (Cursor-native formats with no published JSON schema)
      - */users/*/iterm2/DynamicProfiles/*.json
      - */users/*/obsidian/*.json
      - */users/*/qtpass/*.json
      - */configs/camilladsp/*, */configs/camillagui-backend/*
      - */users/*/discord-music-rpc/*
      - */users/*/agents/hooks/*.json
      - */users/*/agents/skills/*/_meta.json (ClawHub skill metadata, generated/managed)
      - */ai/litellm-config.yml
      - */.sops.yaml
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

- `testing.instructions.md` — Test structure, CI integration, and validation patterns.
- `tooling-and-validation.instructions.md` — Repository tooling, build commands, and validation hooks.
- `allow-and-deny-lists.instructions.md` — Step 7 EXCEPTION_LIST registry and exclude-list policy.
