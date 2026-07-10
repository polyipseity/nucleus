---
description: "Use when authoring markdown documents and output-format-sensitive content. Covers line wrapping, document structure, and formatting conventions."
name: "Authoring and Output Format"
applyTo: "**"
---

Default rule: write for readability in raw form, not for rendered aesthetics.

## Markdown line wrapping

Do not insert hard line breaks to keep paragraphs under a certain column width. Markdown viewers render content readably — hard-wrapping only makes raw files harder to navigate and edit.

**Exception**: when a validator or linter enforces a maximum line length, follow the tool's requirement.

## `.instructions.md` editing rules

`.instructions.md` files are loaded as agent context and must stay concise.

- **Prefer inline integration.** A two-word tweak to an existing paragraph is better than a new bullet. A new bullet in an existing list is better than a new section. A new section is better than appending to the file end.
- **Place by topic, not by end-of-file.** Find the most specific existing section that matches each fact. If a fact belongs inside an existing paragraph or bullet list, integrate it there — do not add a section elsewhere.
- **Split facts across sections.** When a concept touches multiple topics, place each fragment in the section where it belongs rather than dumping everything in one place.
- **Plan all edits first.** Before applying any changes, decide all edits across all target sections and files. Order edits bottom-up within each file and apply with a single `multi_replace_string_in_file` call per file.

## Document conventions

- **Sentence case headings.** Capitalize only the first word and proper nouns.
- **Code references.** Wrap file paths, command names, and inline code in backticks.
- **Parallel list structure.** Keep bullet items grammatically parallel — all nouns, all imperatives, or all full sentences, not a mix.
- **Minimal emphasis.** Use **bold** for key terms and rules only. Overused emphasis dilutes its effect.
