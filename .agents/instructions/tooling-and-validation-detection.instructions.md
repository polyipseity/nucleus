---
description: "Use when creating or updating instructions for repository tooling, build commands, tests, CI, editor automation, or validation workflows. Also covers detecting the repository's programming languages, frameworks, runtimes, package managers, and setup from concrete files before writing detailed guidance."
name: "Tooling and Validation Detection"
applyTo: "AGENTS.md, .agents/instructions/**/*.md, opencode.jsonc, .vscode/settings.json, .github/workflows/**/*.yml, .github/dependabot.yml, .editorconfig, .gitattributes"
---

# Tooling and Validation Detection

## Discovery before prescription

- Treat stack and tooling discovery as an evidence-based process.
- Before you write language-specific, framework-specific, runtime-specific, or
  automation-specific instructions, determine what the repository actually uses.
- Inspect the files that define the repository's actual setup: dependency
  manifests, lockfiles, build/test/linter/formatter configs, CI workflows,
  scripts, editor settings, automation configs, source directories, file
  extensions, and representative entrypoints.
- If the repository is still a sparse template, describe the workflow as
  conditional or not yet initialized instead of pretending commands already
  exist.

## Detection order

- Start with the highest-signal files and directories:
  - workspace-wide guidance such as `AGENTS.md`
  - dependency manifests and lockfiles
  - build, test, formatter, linter, and compiler configs
  - CI workflows and repo scripts
  - source directories, file extensions, and representative entrypoints
  - editor settings and automation configs
- Prefer multiple signals over a single clue when deciding that a stack is
  truly in use.
- If evidence conflicts, document the ambiguity and avoid inventing hard rules
  until the repository structure clarifies the intended setup.

## What to detect

- Programming languages in active use, not merely hinted at by empty folders.
- Frameworks, build systems, package managers, test runners, linters,
  formatters, type checkers, documentation generators, and release tooling.
- Directory boundaries that deserve their own instructions because they follow
  different conventions.
- Canonical commands, if any, and where they are defined.
- Platform-specific constraints such as line endings, executable bits, or shell
  assumptions.

## Evidence standards

- A single empty directory is weak evidence.
- A real config file, lockfile, script, workflow step, or representative source
  file is strong evidence.
- Comments in docs are weaker than executable config unless the docs are clearly
  the source of truth.
- Prefer on-disk facts over habits carried from similar repositories.

## Command discovery

- Identify canonical commands from task-runner configs, scripts, CI steps, and
  workspace docs.
- Record where each command comes from so instructions can be updated when the
  source of truth changes.
- If several entrypoints wrap the same behavior, document the canonical one and
  note the wrappers briefly instead of duplicating the whole command matrix.

## GitHub CLI usage (noninteractive by default)

- All `gh` commands in automation, validation, and agent execution must run in
  noninteractive mode.
- Set `GH_PROMPT_DISABLED=1` and `GH_PAGER=cat` when invoking `gh` to avoid
  blocking on prompts or pager sessions.
- Prefer explicit machine-readable output (`--json`, optionally `--jq`) over
  interactive flows.
- Avoid interactive commands (for example `gh run watch`) in agent workflows;
  poll status with noninteractive list/view commands instead.

## Config coordination

- When you change an instruction about tooling, check the neighboring configs in
  the same pass:
  - CI workflows
  - editor automation
  - dependency update automation
  - formatting and line-ending config
  - prompt files that tell agents how to run checks
- Keep those files consistent so the repo does not describe one workflow while
  automating another.
- When documenting test coverage or test inventory, derive counts and file
  lists from the current `tests/` tree and CI workflow globs, not from stale
  prose copied from older docs.
- Do not leave placeholder statements that claim tests are absent when
  test files or validation workflows already exist.
- In instruction examples, prefer real in-repo file names over hypothetical
  names unless the example is explicitly labeled as illustrative.

## How to write follow-up instructions

- When a stack is detected or a repository gains a clearly defined language or
  framework setup, create or refine a focused instruction file whose `name`,
  `description`, and `applyTo` clearly target that stack.
- Keep repo-wide discovery rules in `AGENTS.md` and stack details in dedicated
  files; do not overload the root guidance.
- Make the instruction thorough and evidence-backed: code structure, tests,
  commands, key config files, source locations, testing expectations, common
  failure modes, and validation workflow for that stack.
- Keep `applyTo` globs narrow so the detailed instruction only loads for the
  files it truly governs.
- Link to canonical config files instead of copying long option lists unless a
  short inline summary is critical to agent behavior.

## Validation guidance

- For every detected stack, document how agents should validate changes:
  - what to run
  - where the commands are defined
  - what files act as the source of truth
  - what should be avoided when the stack is only partially initialized
- When specific identifiers/settings are not covered by executable validation
  (for example app IDs, bundle IDs, launch labels, registry keys, env-var
  names, or preference domains), require inline source citations adjacent to
  those settings so reviewers can verify each one independently.
- Treat syntax validation as mandatory: always run at least one syntax/parse
  check for each changed file type before concluding. Prefer repository-defined
  commands (for example `nix-instantiate --parse <file.nix>`, `nix flake check`
  from `src/`, `nix shell nixpkgs#powershell -c pwsh ...`, and
  `winget configure --what-if .\src\hosts\windows\system.dsc.yml` with
  `winget configure --what-if .\src\hosts\windows\user.dsc.yml`).
- Treat `package-ecosystem: "nix"` in `.github/dependabot.yml` as valid even
  when `check-dependabot` reports a schema error; that validator can lag
  Dependabot ecosystem support.
- When no runnable validation exists yet, say that explicitly and point to the
  files that would need to be added before validation can be automated.

## What to avoid

- Do not assume a default language or task runner just because a similar repo
  used one.
- Do not keep stale stack-specific files after the repo has been generalized or
  reoriented.
- Do not leave broad placeholders such as "follow standard best practices" when
  concrete repository evidence can support sharper guidance.
