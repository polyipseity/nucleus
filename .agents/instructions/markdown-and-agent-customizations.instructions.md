---
description: "Use when editing markdown docs, AGENTS.md, prompt files, or agent customization markdown. Covers repo-specific markdownlint rules, linking strategy, mirrored prompts, and safe YAML frontmatter."
name: "Markdown and Agent Customizations"
applyTo: "AGENTS.md, .agents/**/*.md, .opencode/**/*.md, .github/**/*.md"
---

# Markdown and Customization Authoring

Use this file for markdown guidance only. Keep policy canonical in `AGENTS.md` and focused `.agents/instructions/*.instructions.md` files.

## Core rules

- Keep docs short, scannable, and repo-specific.
- Link to canonical files instead of copying long policy blocks.
- Prefer relative links/paths that survive repository relocation.
- If something is not present yet, mark it as optional/future-facing.

## Markdownlint and formatting

- Follow `.markdownlint.jsonc` (root) and `.agents/.markdownlint.jsonc` (under `.agents/**`).
- Do not hard-wrap paragraphs for line length (`MD013` is disabled).
- Inline HTML and bare anchors are allowed where useful (`MD033`, `MD051` disabled).
- Under `.agents/**`, emphasis-only pseudo-headings are allowed (`MD036` disabled).

## Frontmatter and prompts

- Keep valid YAML frontmatter in `.instructions.md` and `.prompt.md` files.
- Quote `description` and start it with "Use when ...".
- Keep `applyTo` narrow and specific.
- Keep `name` stable and purpose-driven.
- Preserve prompt interfaces (`argument-hint`, `${input:...}`) unless changing them intentionally.

## Mirroring and safety

- `commit-staged.prompt.md` is intentionally duplicated in three locations; body content must match (frontmatter tool-specific keys such as `disable-model-invocation` may differ per consumer):
  - `.agents/prompts/commit-staged.prompt.md` (repo / OpenCode)
  - `.opencode/commands/commit-staged.prompt.md` (symlink to repo copy)
  - `src/users/default/agents/prompts/commit-staged.prompt.md` (user overlay / Cursor)
- Do not add `.github/copilot-instructions.md`; root `AGENTS.md` is canonical.
- Avoid broad cosmetic rename sweeps unless all dependent references are updated atomically.
