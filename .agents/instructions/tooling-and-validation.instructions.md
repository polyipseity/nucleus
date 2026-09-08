---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and Validation Detection

## Discovery before prescription

- Detect actual repo usage before writing stack-specific instructions.
- Inspect: dependency manifests, lockfiles, build/test/lint configs, CI workflows, scripts, editor settings, source dirs, entrypoints.
- Sparse template? Describe as conditional — don't pretend commands exist.
- Order: workspace guidance → manifests → build/test/lint configs → CI → source layouts → editor/automation.
- Record directory boundaries with different conventions.

## Command discovery

- Canonical commands from task-runner configs, scripts, CI, docs. Record provenance.
- Multiple entrypoints? Document canonical, note wrappers briefly.

## GitHub CLI

Noninteractive only: `GH_PROMPT_DISABLED=1`, `GH_PAGER=cat`. Prefer `--json`/`--jq`. No `gh run watch` — poll via list/view.

## Config coordination

- Change tooling instructions → update neighboring configs same pass.
- Derive test counts from current `tests/` tree, not stale prose.
- Prefer real repo file names in examples.

## Skill vs instruction vs AGENTS.md

- **AGENTS.md**: durable conventions, ~30 lines/section max.
- **`.instructions.md`**: file-type-scoped, narrow `applyTo`, lean.
- **`SKILL.md`**: on-demand, avoid duplicating AGENTS.md.

## Follow-up instructions

New stack → focused instruction file. Narrow `applyTo`, link canonical configs, back with evidence.

## Validation guidance

### Tool availability policy

No skip-guards. Missing tool → script fails loudly.

- **Provisioning ≠ preflight.** Provisioning installs; preflight verifies and hard-fails.
- No `command -v <tool> || return 0`, no `Get-Command -ErrorAction SilentlyContinue` gating, no `Test-Path` skip-guards.
- Allowed: alternative selection between equivalents; preflight that `exit 1` on absence; config-driven optional features.

Scope: `scripts/`, `tests/`, `src/scripts/`, `src/platforms/Windows/modules/`.

### Check script structure

- Steps by group; numbers from `check-steps/<nn>-*` filenames. Group layout in `step-runner.instructions.md`.
- Windows: steps 3-4 stubs (POSIX/Nix-only). Pre-flight at script start.
- New tools → add to both preflight and provisioning.
- **Source of truth:** step filenames and header docstrings.

### Check modes

- **Always-run:** whole-repo invariants, no `$HAS_ARGS`. Steps 6, 8, 14 sub-checks.
- **Conditional:** file-type dependent (scoped) or always (`--full`). Steps 3, 5, 11.
- **Path-scopable:** per-file/type with path filtering. Steps 1, 2, 4, 7, 9, 12, 14 sub-checks.

### Scoped-mode (`_has_args`)

- **POSIX:** `$1=_has_args`, `$2=_repo_root`, rest = files. Skip (steps 7, 12): no match → `skip_step` + `return 2`.
- **PowerShell:** `param($HasArgs, $RepoRoot, $PositionalArgs)`. No match → `Skip-Step` + `return 2`.
- **`$null` trap:** empty pipeline enumerates to `$null`, `.Count` throws. Wrap in `@(...)` with `# WHY:`.

### Stack-specific

- **Nix check-and-format:** `check.sh --format` via treefmt. Flag from `prek.toml` `args = ["--format"]`. No separate `format-nix` hook.
- **nixf-tidy:** `nixf-tidy < file` (stdin; positional hangs). Run before Nix test edits.
- **deadnix in tests:** Findings are real (lazy eval). Fix: remove or `builtins.seq (builtins.deepSeq { ... } null)`. `deepSeq` is two-arg; one-arg is partial lambda → dead assertions, green tests.
- **Commit validation:** commitlint via `prek.toml`. Types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Pre-validate via temp-dir `bun install` — `bun x commitlint` can't resolve deps. Remove artifacts after.
- **prek auto-install:** `prek install --quiet` every apply + shell entry. Always-install, idempotent. Refuses external `core.hooksPath` (exit 2) — honor loudly. `--prepare-hooks` opt-in.
- **prek stashing:** Stashes unstaged during commit, restores after. Normal.
- **prek concurrency:** `require_serial = true` on `repo-check`/`repo-test` to avoid treefmt/Nix cache races. Subagents must not commit/push. Warm cache from git real path, not symlink (different cache dbs). Never `treefmt --no-cache`.
- **CI:** No new checks/tests in `ci.yml` — route into repo checks or tests.
- Inline source citations for non-validated identifiers. Syntax validation mandatory per changed file type. No runnable validation? State explicitly and name files needed.
