---
description: "Use when implementing or modifying the step-runner framework used by the check and test pipelines. Covers step registration, declared applicability (platform, mode, requires), the --only-steps selector, run-state rendering, PS1 parallelism, and step 7 $schema enforcement."
name: "Step-Runner Framework"
applyTo: "src/scripts/lib/step-runner.sh, src/scripts/lib/step-runner.ps1, scripts/check.sh, scripts/check.ps1, scripts/test.sh, scripts/test.ps1, tests/scripts/**, src/scripts/checks/check-steps/**, src/scripts/tests/test-steps/**"
---

# Step-runner framework interface specification

Both POSIX (`step-runner.sh`) and PowerShell (`step-runner.ps1`) implementations must conform.

## Spec A: Step registration

```text
register_step(id, name, func)                                 # 3-arg: platform=any mode=any requires=none
register_step(id, name, func, platform, mode, requires)       # 6-arg: declared applicability
register_step(id, number, name, func)                         # 4-arg: unit tests only ($2 must be [0-9]+)
  Arity is exactly 3, 4 or 6; the 4-arg form is unit-tests only.
  id: non-empty, no digits, unique, kebab-case. number: positive, unique.
  3-arg: number from NN- prefix (error if missing). 4-arg: explicit (unit tests only).
  name: display name. func: (ctx, ...files).
  platform: any | posix | windows. posix = macOS and NixOS only; windows = Windows only.
  mode: any | full | scoped. scoped = run with positional file args; full = whole-repo run.
  requires: none | nix | network | sops-machine-key | deployed-host.
  Validation (hard failure): id digit/empty/dup; number dup; unknown token.
    register_step: unknown platform token 'darwin' (expected posix|windows|any)
  Effect: appends to step arrays (POSIX _STEP_IDS/_STEP_PLATFORMS/_STEP_MODES/_STEP_REQUIRES; PS1 $script:StepIds/…).
PowerShell named form: Register-Step -Id -Name -Action [-Number] [-Platform] [-Mode] [-Requires]; defaults any/any/none.
```

## Spec B: `--only-steps` flag

```text
Flag: --only-steps=id1,id2,id3 (= mandatory; no space-separated form). check-pwsh.ps1 uses -OnlyStep <PSSA|Syntax>.
Comma-separated step IDs, whitespace trimmed, duplicates deduped. Empty = no-op.
Execution: an id not selected → "=== [<number>] <name> === not-selected" (not run, no exit effect).
Errors: unknown id is a hard error with the known-id list; no negation flag and no alias. Multiple flags last wins.
Interactions: selection is applied before the platform/mode/requires checks; --fail-fast unaffected.
```

## Spec C: `--format` removal (post-removal behavior)

```text
Step 01 (code-formatting): always runs `treefmt` in-place (no --fail-on-change).
Pipelines may silently reformat — run `git status --short` after and commit `style(...)` fixes.
  POSIX: treefmt + Darwin supplements + check-packer --validate-only
  PS1: native CLIs (shfmt, yamllint, taplo, packer fmt, actionlint, pinact, zizmor, check-packer)
  Same output format.
```

## Spec D: `--skip-system-build` removal

```text
Test step 04 (system-config-build):
  POSIX: declares `requires sops-machine-key`; the runner reports it not applicable when the key is absent.
  Windows: no counterpart — the system build has no PowerShell twin. No flag controls execution.
```

## Spec E: PS1 parallelism

```text
Invoke-StepPipeline:
  - Waves capped at PARALLEL_JOBS (default: CPU count).
  - [PowerShell]::Create() + BeginInvoke() per step (one runspace; no RunspacePool/Start-Job).
  - Per-step stdout/exit/timing → step-N.* files in wave temp dir.
  - Live [step NN] on stderr; ordered replay step-number order.
  - Timing: `%.3f s` summary; internal integer ms. POSIX: $EPOCHREALTIME / Time::HiRes / date +%s%3N.
  - Exit code 0 (all selected applicable steps passed) or 1 (any failed). Fail-fast: stop after current wave.
```

### Output color

F2/F4 palette via `_nuc_color_init` (POSIX, `src/scripts/lib/lib.sh`) / `$PSStyle` (PS1, `Format-NucleusOutput.psm1`). No raw ANSI/tput/echo-e (check step 14).

- F1: `notice` bold blue; semantic coloring (URLs underline-cyan, quotes blue).
- F2: `[step NN]` dim. F4: ✓ green / ✗ red / – (en dash) yellow for not applicable or not selected; labels dim.
- Captured files plain. Gated by NO_COLOR / FORCE_COLOR / tty (`output-handling.instructions.md`).

## Spec F: Declared applicability

```text
The runner decides whether a registered step runs, from its declaration:
  - selection: an id excluded by --only-steps → "not-selected";
  - platform: posix needs macOS or NixOS, windows needs Windows → "not applicable (platform: <token>)";
  - mode: scoped needs positional args, full needs none → "not applicable (mode: <token>)";
  - requires: nix | network | sops-machine-key | deployed-host → "not applicable (requires: <token>)".
A step never probes its own prerequisites; the runner owns run-state.
Not-applicable and not-selected steps never affect the exit code (0 pass / 1 fail).
Never output "passed" or "no issues found" for a step that did not run.
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

  EXCEPTION_LIST:
  Schema definitions/meta: *.schema.json
  External formats (no published schema): */users/*/cursor/*.json,
  */users/*/iterm2/DynamicProfiles/*.json, */users/*/obsidian/*.json, */users/*/qtpass/*.json,
  */users/*/rimsort/*.json, */configs/camilladsp/*, */configs/camillagui-backend/*,
  */users/*/discord-music-rpc/*, */users/*/agents/hooks/*.json,
  */users/*/agents/skills/*/_meta.json, */configs/litellm/*,
  */users/*/hermes/plugins/*/plugin.yaml,
  */users/*/vscode/mcp.json, */users/*/vscode/chatLanguageModels*.json, */.sops.yaml
  Infrastructure: */vendor/*, */secrets/*, */.github/*
  Registered in allow-and-deny-lists.instructions.md.
  Policy: nucleus-owned data requires $schema (we write our own schemas).
  External formats: use published $schema when available; never roll our own.

  Aggregation: collect all → step fails if any. "ERROR: <N> file(s) missing or invalid $schema"
  Cross-platform: identical.
```

## No ambient passing of shared state

Steps must not read enclosing-scope state not passed as parameters. State flows through the context object only.

Context as first parameter: PowerShell `$Context.<Field>` (`[PSObject]` from `step-runner.ps1`); Bash `${ctx[...]}` (associative array via `local -n ctx="$1"` from `step-runner.sh`).

Steps read only context + own `local`/`$local:` vars. Private accumulators must not be written to shared scope. Exception: documented env inputs (`REPO_ROOT`, `NUCLEUS_REPO_ROOT`, `PARALLEL_JOBS`) — mark with `# WHY:` if non-obvious.

Why: PowerShell runspaces cannot inherit `$script:` — reads fail or corrupt via concurrent access. Bash subshells copy globals silently.
