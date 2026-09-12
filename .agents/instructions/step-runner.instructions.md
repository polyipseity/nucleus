---
description: "Use when implementing or modifying the step-runner framework used by the check and test pipelines. Covers step registration, --skip-steps semantics, removed flags, skip message format, PS1 parallelism, and step 7 $schema enforcement."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework interface specification

Both POSIX (`step-runner.sh`) and PowerShell (`step-runner.ps1`) implementations must conform.

## Spec A: Step ID registration

```text
register_step(id: str, name: str, func: Function)                # 3-arg: number from NN- prefix
register_step(id: str, number: int, name: str, func: Function)   # 4-arg: unit tests only
  id: non-empty, no digits, unique, kebab-case. number: positive, unique.
  3-arg: from NN- prefix (error if missing). 4-arg: explicit (unit tests only).
  name: display name. func: (has_args, repo_root, ...files).
  Validation (hard failure): id digit/empty/dup; number dup.
  Effect: appends to step arrays (POSIX _STEP_IDS; PS1 $script:StepIds).
```

## Spec B: `--skip-steps` flag

```text
Flag: --skip-steps=id1,id2,id3 (= mandatory; no space-separated form).
Comma-separated step IDs, whitespace stripped. Empty = no-op.
Effect: Populates SKIP_STEPS (POSIX) / $script:SkipSteps (PS1).
Execution: if id in SKIP_STEPS → "=== [<number>] <name> === SKIPPED" (exit 2).
Errors: unknown ignored; duplicates deduped; multiple flags last wins.
Interactions: --fail-fast skipped steps don't trigger; --scoped --skip-steps takes priority.
```

## Spec C: `--format` removal (post-removal behavior)

```text
Step 01 (code-formatting): always runs `treefmt` in-place (no --fail-on-change). Skipped only if absent.
Pipelines may silently reformat — run `git status --short` after and commit `style(...)` fixes.
  POSIX: treefmt + Darwin supplements + check-packer --validate-only
  PS1: native CLIs (shfmt, yamllint, taplo, packer fmt, actionlint, pinact, zizmor, check-packer)
  Same output format.
```

## Spec D: `--skip-system-build` removal

```text
Test step 04 (system-config-build):
  POSIX: runs on macOS/Linux; skips "SKIPPED (unsupported host <host>)" otherwise.
  PS1: always skips "SKIPPED (POSIX-only test suite)". Exit 2. No flag controls execution.
```

## Spec E: PS1 parallelism

```text
Invoke-StepPipeline:
  - Waves capped at PARALLEL_JOBS (default: CPU count).
  - [PowerShell]::Create() + BeginInvoke() per step (one runspace; no RunspacePool/Start-Job).
  - Per-step stdout/exit/timing → step-N.* files in wave temp dir.
  - Live [step NN] on stderr; ordered replay step-number order.
  - Timing: `%.3f s` summary; internal integer ms. POSIX: $EPOCHREALTIME / Time::HiRes / date +%s%3N.
  - Error: exit code = max. Fail-fast: stop after current wave. --skip-steps excluded.
```

### Output color

F2/F4 palette via `_nuc_color_init` (POSIX, `src/scripts/lib/lib.sh`) / `$PSStyle` (PS1, `Format-NucleusOutput.psm1`). No raw ANSI/tput/echo-e (check step 14).

- F1: `notice` bold blue; semantic coloring (URLs underline-cyan, quotes blue).
- F2: `[step NN]` dim. F4: ✓ green / ✗ red / SKIP yellow / ⊘ yellow; labels dim.
- Captured files plain. Gated by NO_COLOR / FORCE_COLOR / tty (`output-handling.instructions.md`).

## Spec F: Silent skip elimination

```text
Every step that does not run: output "=== [<number>] <name> === SKIPPED (<reason>)".
All skips via skip_step helper (F3). Exit 2 (not failure; SKIP in results).
Never output "passed" or "no issues found". Single canonical skip path.
```

## Check step groups

| Group | Steps | IDs |
| ----- | ----- | --- |
| Format/lint | 01–02 | `code-formatting`, `powershell-lint` |
| Nix | 03–04 | `nix-flake-eval`, `nix-lint` |
| Data/schema | 05–08, 10 | `lockfile-validation`, `locked-dsc-validation`, `schema-validation`, `service-registry`, `completions-fresh` |
| Repo policy | 11–14 | `package-manager-enforcement`, `suppression-audit`, `online-determinism`, `repository-policy` |

## Adding or renumbering check steps

Step numbers from `NN-` filename prefix of `src/scripts/checks/check-steps/<nn>-*.{sh,ps1}`. IDs digit-free kebab-case. Renumbering = filename change + reference sweep.

References to move: `TEST_FILE`/`$testFile`, `# shellcheck source=`, prose "step N", `repository-policy.awk`, generator/installer comments, groups table, test pairs.

- **No blind appending** — number must reflect function and group.
- **Group first, number second** — new groups require justification + renumbering.
- **Rename first, then create** — `git mv` step+test pairs, update all references, create new pair, one atomic commit.
- **Test-pipeline steps**: same principles.

Shell validation runs in test step 5, not check pipeline.

## Spec G: Step 7 `$schema` enforcement

```text
For every JSON/YAML file in scope (except exceptions):
  1. Presence: lacks `$schema` + not in EXCEPTION_LIST → ERROR "Missing $schema in <filepath>"
  2. Validity: relative path + file missing → ERROR "Schema file not found: '<path>' (referenced from <filepath>)"
  3. Format: empty or non-string → ERROR "Invalid $schema in <filepath>: must be a non-empty string"
  Continue checking all files (non-fatal per-file).

  EXCEPTION_LIST (*.schema.json, vendor/**, secrets/**, .github/workflows/*.yml,
  .github/dependabot.yml, .gitignore, .gitkeep, package.json, opencode.jsonc,
  App-owned with no published schema: */users/*/vscode/*.json, */users/*/cursor/*.json,
  */users/*/iterm2/DynamicProfiles/*.json, */users/*/obsidian/*.json, */users/*/qtpass/*.json,
  */configs/camilladsp/*, */configs/camillagui-backend/*, */users/*/discord-music-rpc/*,
  */users/*/agents/hooks/*.json, */users/*/agents/skills/*/_meta.json,
  */configs/litellm/config.yml, */.sops.yaml)
  Registered in allow-and-deny-lists.instructions.md.

  Aggregation: collect all → step fails if any. "ERROR: <N> file(s) missing or invalid $schema"
  Cross-platform: identical.
```

## No ambient passing of shared state

Steps must not read enclosing-scope state not passed as parameters. State flows through the context object only.

Context as first parameter: PowerShell `$Context.<Field>` (`[PSObject]` from `step-runner.ps1`); Bash `${ctx[...]}` (associative array via `local -n ctx="$1"` from `step-runner.sh`).

Steps read only context + own `local`/`$local:` vars. Private accumulators must not be written to shared scope. Exception: documented env inputs (`REPO_ROOT`, `NUCLEUS_REPO_ROOT`, `PARALLEL_JOBS`) — mark with `# WHY:` if non-obvious.

Why: PowerShell runspaces cannot inherit `$script:` — reads fail or corrupt via concurrent access. Bash subshells copy globals silently.
