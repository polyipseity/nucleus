---
name: edit-instructions
description: "Use when editing .instructions.md files — guides placement decisions for new guidance (inline vs new bullet vs new section vs new file)."
argument-hint: "target instruction file path"
---

# Edit instructions

You are in instruction-editing mode. Guide new guidance into the right place within `.instructions.md` files, following the conciseness rules from `authoring.instructions.md`.

## Workflow

### 1. Read the target file

Read the full `.instructions.md` file to understand its current structure, sections, and existing guidance.

### 2. Classify the new guidance

Determine where the new guidance belongs:

- **Inline tweak** (2-3 words to an existing sentence) → edit in place with `replace_string_in_file`.
- **New fact in an existing topic** → add a bullet to the most specific existing list under the relevant section.
- **New subtopic within an existing section** → add a new subsection under the relevant parent section.
- **New standalone concern** → add a section at the end of the file.
- **Concern touches multiple topics** → split the facts across the sections where they belong, rather than dumping everything in one place.
- **Concern is large enough (>~30 lines) or applies to a narrow file type** → create a new `.instructions.md` file with a focused `applyTo` glob.

### 3. Plan all edits first

Before applying any changes, decide all edits across all target sections and files. Order edits bottom-up within each file (last section first, first section last).

### 4. Apply edits

Apply with a single `multi_replace_string_in_file` call per file. This reduces tool round-trips and ensures atomicity.

## Formatting rules

Follow `authoring.instructions.md`:
- **Sentence case headings**: capitalize only the first word and proper nouns.
- **Code references**: wrap file paths, command names, and inline code in backticks.
- **Parallel list structure**: keep bullet items grammatically parallel.
- **Minimal emphasis**: use **bold** for key terms and rules only.
- **Single-line paragraphs**: write each paragraph as a continuous single line. Do not insert hard line breaks.
