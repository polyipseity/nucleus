---
description: "Use when editing markdown docs, AGENTS.md, prompt files, or agent customization markdown. Covers repo-specific markdownlint rules, linking strategy, mirrored prompts, and safe YAML frontmatter."
name: "Markdown and Customization Authoring"
applyTo: "AGENTS.md, README.md, .agents/**/*.md, .opencode/**/*.md, .github/**/*.md"
---
# Markdown and Customization Authoring

## Scope and intent

- Use this instruction for human-facing docs and agent customization markdown:
  `AGENTS.md`, `.instructions.md`, `.prompt.md`, skill docs, mirrored OpenCode
  prompts, and markdown under `.github/`.
- Keep root `AGENTS.md` durable and repo-wide. Move file-type details into
  focused instruction files instead of turning `AGENTS.md` into a mini wiki.
- This repository is a sparse template. If a downstream file is not present
  yet, describe it as optional or future-facing rather than as an existing
  fact.

## Repo-specific markdown behavior

- Follow `.markdownlint.jsonc` at the repo root and `.agents/.markdownlint.jsonc`
  for files under `.agents/`.
- Do not hard-wrap paragraphs just to satisfy line-length rules; `MD013` is
  disabled.
- Inline HTML and bare anchor behavior are permitted where they clearly improve
  the document; `MD033` and `MD051` are disabled.
- Under `.agents/**`, `MD036` is also disabled, so emphasis-only pseudo-headings
  are allowed when they genuinely improve readability.

## Writing style

- Keep content scannable, task-oriented, and specific to this repository.
- Prefer short sections, bullets, and explicit file references wrapped in
  backticks.
- Use "link, don't embed": point to canonical files such as
  `.github/workflows/ci.yml`, `.commitlintrc.mjs`, `opencode.json`, or
  `.vscode/settings.json` instead of duplicating long policy blocks.
- When documenting commands, reflect the commands that actually exist in the
  repo. If the template has not been initialized yet, say so plainly.

## Detection-first customization updates

- When creating or revising stack-specific guidance, inspect repository evidence
  before you write rules:
  - manifests and dependency metadata
  - lockfiles
  - compiler, linter, formatter, and test configs
  - CI workflows and local scripts
  - source tree layout and representative files
- Do not hard-code language, framework, package-manager, or test-runner rules
  unless the repository contains concrete evidence for them.
- Once a stack is detected, add instructions for it carefully and thoroughly in
  a focused file instead of sprinkling partial guidance across unrelated docs.
- If no stack can be proven from files on disk, document the repo as
  uninitialized or stack-agnostic rather than guessing.

## Customization frontmatter

- Every `.instructions.md` and `.prompt.md` file must keep valid YAML
  frontmatter between `---` markers.
- Quote `description` values, especially when they contain colons or commas.
- Make `description` keyword-rich and phrase it like "Use when ..." so the
  agent can discover the file.
- Keep `applyTo` globs as narrow as practical; avoid broad wildcards unless the
  rule truly applies everywhere.
- Use a stable, human-readable `name` that matches the file's primary purpose.
- For prompt files, preserve `argument-hint` fields and `${input:...}`
  placeholders exactly unless you are intentionally changing the interface.

## Mirrored prompt files

- `.agents/prompts/commit-staged.prompt.md` and
  `.opencode/commands/commit-staged.prompt.md` are mirrored copies today.
- If you edit one mirrored prompt, update the other in the same change unless
  you are intentionally diverging the two surfaces and documenting why.
- Keep shell examples platform-accurate: PowerShell examples should use
  PowerShell-native quoting, and Bash/zsh examples should use heredocs safely.

## Safe editing patterns

- Do not add `.github/copilot-instructions.md`; root `AGENTS.md` is the
  workspace-wide source of truth here.
- Prefer relative file references that remain valid when the repo is cloned to
  a different path.
- When mentioning future manifests, task files, or tool configs, distinguish
  between "present now" and "expected after initialization."
