---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/check.ps1, scripts/prek-hooks.py"
---

# Tooling and Validation Detection

## Discovery before prescription

Detect actual repo usage before writing stack-specific instructions. Inspect manifests, lockfiles, build/test/lint configs, CI, scripts, editor settings, source dirs, entrypoints. Sparse template? Describe as conditional. Order: workspace guidance → manifests → configs → CI → source layouts → editor/automation.

## Command discovery

Canonical commands from task-runner configs, scripts, CI, docs. Record provenance. Multiple entrypoints → document canonical, note wrappers briefly.

## GitHub CLI

Noninteractive only: `GH_PROMPT_DISABLED=1`, `GH_PAGER=cat`. Prefer `--json`/`--jq`. No `gh run watch`.

## Config coordination

Change tooling instructions → update neighboring configs same pass. Test counts from current `tests/` tree, not stale prose. Prefer real repo file names in examples.

**AGENTS.md** = durable conventions (~30 lines/section). **`.instructions.md`** = file-type-scoped, narrow `applyTo`. **`SKILL.md`** = on-demand reference, don't duplicate AGENTS.md.

## Validation guidance

### Tool availability

No skip-guards. Missing tool → script fails loudly. Provisioning installs; preflight verifies and hard-fails. No `command -v <tool> || return 0`, no `Get-Command -ErrorAction SilentlyContinue` gating, no `Test-Path` skip-guards. Allowed: alternative selection between equivalents; preflight `exit 1`; config-driven optional features.

Scope: `scripts/`, `tests/`, `src/scripts/`, `src/platforms/Windows/modules/`.

### Check script structure

Steps by group; numbers from `check-steps/<nn>-*` filenames. Group layout in `step-runner.instructions.md`. Windows: steps 3-4 stubs. New tools → add to both preflight and provisioning. **Source of truth:** step filenames and header docstrings.

### Check modes

- **Always-run:** whole-repo invariants. Steps 6, 8, 14 sub-checks.
- **Conditional:** file-type dependent or always (`--full`). Steps 3, 5, 11.
- **Path-scopable:** per-file/type. Steps 1, 2, 4, 7, 9, 12, 14 sub-checks.

### Scoped-mode (`_has_args`)

POSIX: `$1=_has_args`, `$2=_repo_root`, rest = files. Skip (steps 7, 12): no match → `skip_step` + `return 2`. PowerShell: `param($HasArgs, $RepoRoot, $PositionalArgs)`. `$null` trap: empty pipeline → `$null`, `.Count` throws — wrap in `@(...)` with `# WHY:`.

### Stack-specific

- **Nix format:** `check.sh --format` via treefmt (flag from `prek.toml`). No separate `format-nix` hook.
- **nixf-tidy:** `nixf-tidy < file` (stdin; positional hangs). Run before Nix test edits.
- **deadnix in tests:** Real findings (lazy eval). Fix: remove or `builtins.seq (builtins.deepSeq { ... } null)`. `deepSeq` is two-arg; one-arg = partial lambda → dead assertions, false green.
- **Commit validation:** commitlint via `prek.toml`. Types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Pre-validate: temp-dir `bun install` (bare `bun x` can't resolve deps). Remove artifacts after.
- **prek:** Always-install, idempotent. Refuses external `core.hooksPath` (exit 2). `require_serial = true` on `repo-check`/`repo-test` to avoid cache races. Subagents must not commit/push. Warm cache from git real path, not symlink (different cache dbs). Never `treefmt --no-cache`.
- **CI:** No new checks/tests in `ci.yml` — route into repo checks or tests.

Inline source citations for non-validated identifiers. Syntax validation mandatory per changed file type. No runnable validation? State explicitly and name needed files.
