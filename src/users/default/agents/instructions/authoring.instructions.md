---
description: "Use when authoring markdown documents and output-format-sensitive content. Covers line wrapping, document structure, and formatting conventions."
name: "Authoring and Output Format"
applyTo: "**"
alwaysApply: true
---

Write for readability in raw form, not for rendered aesthetics.

## Markdown line wrapping

Write each paragraph as one continuous line and let the viewer wrap it. Hard line breaks only make the raw file harder to navigate and edit. When a validator enforces a maximum line length, that wins.

## `.instructions.md` editing rules

These files load as agent context, so they stay concise.

- Prefer inline integration: a tweak to an existing paragraph beats a new bullet, a new bullet beats a new section, and a new section beats appending to the end of the file.
- Place by topic. Put each fact in the most specific existing section it fits, and split a fact that touches several topics across those sections rather than dumping it in one place.
- Plan every edit before applying any: decide the edits across all target sections and files, order them bottom-up within each file, and apply them in one call per file.
- No historical asides. Never annotate what changed, what a value used to be, or what a construct replaced. State the rule as it is now and read git history when prior state matters (see `programming-principles.instructions.md`).

## Document conventions

- Sentence case headings: capitalize the first word and proper nouns only.
- Wrap file paths, command names, and inline code in backticks.
- Keep bullet items grammatically parallel: all nouns, all imperatives, or all full sentences.
- Use bold for key terms and rules only.
