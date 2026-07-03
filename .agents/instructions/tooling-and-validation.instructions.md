---
description: "Use when creating or updating repository tooling, build commands, CI workflows, validation hooks, or authoring instructions about them. Also covers detecting the repository's languages, frameworks, runtimes, and package managers from concrete files."
name: "Tooling and Validation"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes, prek.toml, scripts/check.sh, scripts/prek-hooks.py"
---

# Tooling and Validation Detection

## Discovery before prescription

- Before you write language-specific, framework-specific, runtime-specific, or automation-specific instructions, determine what the repository actually uses.
- Inspect the files that define the repository's actual setup: dependency manifests, lockfiles, build/test/linter/formatter configs, CI workflows, scripts, editor settings, automation configs, source directories, file extensions, and representative entrypoints.
- If the repository is still a sparse template, describe the workflow as conditional or not yet initialized instead of pretending commands already exist.

## Detection targets

- Detect languages, frameworks, build systems, package managers, test runners, linters, formatters, and release tooling from real config files, lockfiles, scripts, CI steps, and source files — not empty directories or assumptions from similar repos.
- Check in order: workspace guidance → dependency manifests → build/test/lint configs → CI workflows → source layouts → editor/automation configs.
- Record directory boundaries that follow different conventions for their own instruction files.

## Command discovery

- Identify canonical commands from task-runner configs, scripts, CI steps, and workspace docs.
- Record where each command comes from so instructions can be updated when the source of truth changes.
- If several entrypoints wrap the same behavior, document the canonical one and note the wrappers briefly instead of duplicating the whole command matrix.

## GitHub CLI usage (noninteractive by default)

- All `gh` commands in automation, validation, and agent execution must run in noninteractive mode.
- Set `GH_PROMPT_DISABLED=1` and `GH_PAGER=cat` when invoking `gh` to avoid blocking on prompts or pager sessions.
- Prefer explicit machine-readable output (`--json`, optionally `--jq`) over interactive flows.
- Avoid interactive commands (for example `gh run watch`) in agent workflows; poll status with noninteractive list/view commands instead.

## Config coordination

- When changing tooling instructions, update neighboring configs (CI workflows, editor/automation configs, formatting/line-ending files, prompt files) in the same pass.
- Derive test coverage counts and file lists from the current `tests/` tree and CI globs — no stale prose or placeholder absence claims.
- In instruction examples, prefer real in-repo file names unless labeled as illustrative.

## Skill vs instruction vs AGENTS.md boundary

When adding new guidance content to this repo, choose the right vehicle:
- **AGENTS.md**: durable project-wide conventions and invariants that every agent needs. Keep short (~30 lines max per section). Per-file-type rules belong in instruction files.
- **`.agents/instructions/*.instructions.md`**: file-type-scoped authoring rules with a narrow `applyTo` glob. Loaded automatically when editing matching files. Not for general reference material — instructions fire on every edit within their scope, so they must be lean and targeted.
- **`.agents/skills/<skill>/SKILL.md`**: reference orientation material loaded on demand via the `skill` tool. Use for content valuable enough to cache but too broad or reference-oriented for an instruction file. Avoid duplicating AGENTS.md.

When editing a skill, check AGENTS.md and the relevant instruction files first for overlapping content.

## How to write follow-up instructions

- When a stack gains a clear setup, create or refine a focused instruction file. Keep `applyTo` narrow, link to canonical configs instead of copying option lists, and keep repo-wide discovery in `AGENTS.md`.
- Make it evidence-backed: code structure, tests, commands, config files, source locations, common failure modes.

## Validation guidance

- For every detected stack, document what to run and where commands are defined.
- **Nix check-and-format (pre-commit hook)**: `check.sh` accepts `--format` to auto-fix Nix files (nixfmt). The flag is passed by `prek-hooks.py` when `args = ["--format"]` in `prek.toml`. `nixfmt` is bundled in `mkCheckApp` runtimeInputs in `src/flake.nix` to avoid expensive nixpkgs eval. No separate `format-nix` hook exists.
- **CI policy**: Do not add new checks or tests to `ci.yml`. Route new validation into repo checks (`scripts/check.sh` / `scripts/check.ps1`) or repo tests (`tests/`). Decouples checks from CI runners so they work locally too.
  - what files act as the source of truth
  - what should be avoided when the stack is only partially initialized
- When specific identifiers/settings are not covered by executable validation (for example app IDs, bundle IDs, launch labels, registry keys, env-var names, or preference domains), require inline source citations adjacent to those settings so reviewers can verify each one independently.
- Treat syntax validation as mandatory: always run at least one syntax/parse check for each changed file type before concluding. Prefer repository-defined commands (for example `nix-instantiate --parse <file.nix>`, `nix flake check` from `src/`, `nix shell nixpkgs#powershell -c pwsh ...`, and `winget configure --what-if .\src\hosts\windows\system.dsc.yml` / `winget configure --what-if .\src\hosts\windows\system-packages.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user-env.dsc.yml` / `winget configure --what-if .\src\hosts\windows\user-context.dsc.yml`).
- When no runnable validation exists yet, say that explicitly and point to the files that would need to be added before validation can be automated.

## What to avoid

- Do not assume a default language or task runner just because a similar repo used one.
- Do not keep stale stack-specific files after the repo has been generalized or reoriented.
- Do not leave broad placeholders such as "follow standard best practices" when concrete repository evidence can support sharper guidance.
