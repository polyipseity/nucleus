---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and Validation Detection

## Discovery before prescription

- Determine what the repository actually uses before writing language/framework-specific instructions.
- Inspect: dependency manifests, lockfiles, build/test/lint configs, CI workflows, scripts, editor settings, source directories, file extensions, entrypoints.
- Sparse template? Describe as conditional — don't pretend commands exist.

## Detection targets

- Detect from real config files, lockfiles, scripts, CI steps, source files — not empty dirs or similar-repo assumptions.
- Order: workspace guidance → dependency manifests → build/test/lint configs → CI → source layouts → editor/automation.
- Record directory boundaries that follow different conventions.

## Command discovery

- Canonical commands from task-runner configs, scripts, CI steps, workspace docs.
- Record provenance so instructions update when source-of-truth changes.
- Multiple entrypoints for same behavior? Document canonical, note wrappers briefly.

## GitHub CLI (noninteractive by default)

- All `gh` commands must run noninteractive: `GH_PROMPT_DISABLED=1` and `GH_PAGER=cat`.
- Prefer `--json`/`--jq` over interactive flows.
- No interactive commands (`gh run watch`) — poll via list/view.

## Config coordination

- Change tooling instructions → update neighboring configs in same pass.
- Derive test coverage from current `tests/` tree and CI globs — no stale prose.
- Prefer real in-repo file names in examples.

## Skill vs instruction vs AGENTS.md

- **AGENTS.md**: durable project-wide conventions. ~30 lines max per section.
- **`.instructions.md`**: file-type-scoped rules with narrow `applyTo`. Lean and targeted.
- **`SKILL.md`**: on-demand reference. Don't duplicate AGENTS.md.

## Follow-up instructions

- New stack gets a focused instruction file. Keep `applyTo` narrow, link canonical configs.
- Back with evidence: code structure, tests, commands, source locations, failure modes.

## Validation guidance

### Tool availability policy

No skip-guards. If a tool is missing, the script fails loudly.

- **Provisioning ≠ preflight.** Provisioning installs (`nucleus-bootstrap`, `nucleus-apply`, DSC). Preflight (`require_command`, `Assert-ToolAvailable`) verifies presence and hard-fails if absent.
- No `command -v <tool> || return 0` / `exit 0`. No `Get-Command -ErrorAction SilentlyContinue` gating. No `Test-Module -ListAvailable` skip-guards. No `Test-Path` test skip-guards.
- Allowed: inline alternative selection between equivalent tools; preflight validation that `exit 1` on absence; config-driven optional features.

Scope: `scripts/`, `tests/`, `src/scripts/`, `src/platforms/Windows/modules/`. Validators reject skip-guard patterns.

### Check script structure

- Steps organized by group; numbers from `src/scripts/checks/check-steps/<nn>-*` filenames. Group layout in `step-runner.instructions.md` — don't duplicate here.
- Windows (check.ps1): steps 3-4 are stubs (POSIX/Nix-only).
- Pre-flight at script start (before `$_step=0`). POSIX: `require_command` from lib.sh. Windows: `Ensure-Tool` from `Ensure-Tool.psm1`.
- New tools → add to both preflight and provisioning.
- **Source of truth:** check-step filenames and header docstrings.

### Check mode taxonomy

- **Always-run:** whole-repo invariants, no path filtering, no `$HAS_ARGS` guard. Examples: DSC validation (step 6), service registry (step 8), repo policy (step 14).
- **Conditional:** run when specific file types present (scoped) or always (`--full`). Examples: Nix flake eval (step 3), lockfile (step 5), package enforcement (step 11).
- **Path-scopable:** per-file/per-type with path filtering. Examples: formatting (step 1), PowerShell syntax (step 2), Nix lint (step 4), schema (step 7), YAML (step 9), suppression audit (step 12), repo policy sub-checks (step 14).

### Scoped-mode conventions (`_has_args`)

- **POSIX:** `$1=_has_args`, `$2=_repo_root`, rest = scoped files. Skip pattern (steps 7, 12): loop for type match; none → `skip_step` + `return 2`.
- **PowerShell:** `param($HasArgs, $RepoRoot, $PositionalArgs)`. Count matching; none → `Skip-Step` + `return 2`.
- **`$null` trap:** empty scoped pipeline enumerates to `$null`, `.Count` throws under StrictMode. Wrap in `@(...)` with `# WHY:` comment.
- Scoped examples: `scripts/check.sh README.md` → steps 5+11 SKIP; `scripts/check.sh src/modules/core.nix` → step 11 runs.

### Stack-specific notes

- **Nix check-and-format:** `check.sh --format` auto-fixes via treefmt (nixfmt-rfc-style). Flag passed by `prek-hooks.py` from `prek.toml`. No separate `format-nix` hook.
- **nixf-tidy:** `nixf-tidy < file` (stdin, NOT positional — `nixf-tidy file` hangs). Run before Nix test edits.
- **deadnix in tests:** Findings are real (Nix lazy eval — unreferenced bindings are genuinely dead). Fix: remove or force with `builtins.seq (builtins.deepSeq { ... } null)`. `deepSeq` is TWO-arg; one-arg returns partial lambda → assertions become dead code while tests report success. `# deadnix: skip` as last resort only.
- **Commit validation:** commitlint via `prek.toml` commit-msg. Valid types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Not `maintain` — use `refactor` or `chore`. Pre-validate via temp-dir install (`bun install` in `mktemp -d`, run commitlint there) — `bun x commitlint` can't resolve `conventional-changelog-conventionalcommits`. Remove `bun install` artifacts after.
- **prek auto-install:** `prek install --quiet` on every apply and shell entry. Always-install, idempotent. Shell hooks try once per session, cache result. Prek refuses external `core.hooksPath` (exit 2) — honor loudly, never `--force`. `--prepare-hooks` is opt-in.
- **prek stashing:** Hooks stash unstaged changes during commit, run checks, restore. Normal behavior.
- **prek concurrency:** `require_serial = true` on `repo-check` and `repo-test` to avoid treefmt bbolt/Nix SQLite cache races. Subagents must not commit/push. Debug: `PREK_CONCURRENT_BATCHES=1`. Warm cache from git real path, not repo-root symlink (different cache dbs). Never `treefmt --no-cache`.
- **CI policy:** No new checks/tests in `ci.yml` — route into repo checks or tests for local use.
- Inline source citations for identifiers not covered by executable validation.
- Syntax validation mandatory for every changed file type.
- No runnable validation? Say so explicitly and name the files needed.
