---
name: edit-instructions
description: "Use when editing .instructions.md files: guides placement decisions for new guidance (inline vs new bullet vs new section vs new file)."
disable-model-invocation: true
argument-hint: "<instruction file path>"
---

# Edit instructions

Read `.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `.agents/instructions/harness-adapters.reference.md`.

Place new guidance correctly inside `.instructions.md` files, following `authoring.instructions.md`.

## Target file

${1:-}

Empty means: list the instruction files under `.agents/instructions/` and stop. Do not guess a target.

## Workflow

1. Read the whole target file first, so its sections and existing guidance are known.
2. Classify the guidance: an inline tweak edits an existing sentence in place; a new fact in an existing topic becomes a bullet in the most specific list; a new subtopic becomes a subsection under its parent; a standalone concern becomes a section at the end of the file; a concern spanning several topics gets split across those sections; a concern over about 30 lines, or one scoped to a narrow file type, becomes its own `.instructions.md` with a focused `applyTo` glob.
3. Plan every edit before applying any, ordering them bottom-up within each file so line numbers hold.
4. Apply with one file edit call per file, which keeps the edits atomic and cuts round-trips.

Formatting follows `authoring.instructions.md`: sentence case headings, backticked file paths and command names, grammatically parallel bullets, bold for key terms only, and one line per paragraph.
