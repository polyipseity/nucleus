---
description: "Use when creating or updating AGENTS.md or instruction files and you need to detect the repository's programming languages, frameworks, runtimes, package managers, and setup from concrete files before writing detailed guidance."
name: "Language and Stack Detection"
applyTo: "AGENTS.md, .agents/instructions/**/*.md"
---
# Language and Stack Detection

## Goal

- Treat stack discovery as an evidence-based process.
- Before you write language-specific, framework-specific, or runtime-specific
  instructions, determine what the repository actually uses.
- Once detected, add instructions for the detected stack carefully and
  thoroughly in focused files with narrow scope.

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

## How to write follow-up instructions

- When a stack is detected, create or refine a focused instruction file whose
  `name`, `description`, and `applyTo` clearly target that stack.
- Keep repo-wide discovery rules in `AGENTS.md` and stack details in dedicated
  files; do not overload the root guidance.
- Make the new instruction thorough enough to cover code structure, tests,
  commands, config files, pitfalls, and validation workflow for that stack.
- Link to canonical config files instead of copying long option lists unless a
  short inline summary is critical to agent behavior.

## What to avoid

- Do not assume a default language or task runner just because a similar repo
  used one.
- Do not keep stale stack-specific files after the repo has been generalized or
  reoriented.
- Do not leave broad placeholders such as "follow standard best practices" when
  concrete repository evidence can support sharper guidance.
