---
name: fuse-memories
description: "Use when: user says 'absorb memories', 'fuse memories', 'merge memories into instructions', or asks to persist session/repo/user memory into agent instructions. Merges selected memory files into repo or user .instructions.md files and deletes the originals."
disable-model-invocation: true
argument-hint: "scope=session,repo | memoryName= | target=repo"
---

# Fuse Memories into Agent Instructions

No confirmation or clarification. Proceed automatically with defaults.

## Inputs

Scope and memoryName are AND-ed — only memories matching both are selected.

| Input | Default | Values |
|-------|---------|--------|
| `${input:scope}` | `session,repo` | Comma-separated from `session`, `repo`, `user` |
| `${input:memoryName}` | (all) | Comma-separated filenames without `.md`. Omit for all in scope. |
| `${input:target}` | `repo` | `repo` → `.agents/instructions/` (project root), `user` → `~/.agents/instructions/` |

## Memory paths

| Scope | Canonical path |
|-------|----------------|
| `session` | `/memories/session/<name>.md` |
| `repo` | `/memories/repo/<name>.md` |
| `user` | `/memories/<name>.md` |

## Probe — find and list memories

Memory files at `/memories/session/` and `/memories/repo/` are directly listable via `memory view`. Do not use filesystem operations (`list_dir`, `file_search`, `resolve_memory_file_uri`) for memory file discovery.

> **Memory tool availability:** If the `memory` tool is not in the available tool list, call `activate_vs_code_interaction` with no arguments first — it is a one-shot call that permanently unlocks VS Code interaction tools.

1. **Check context metadata** — scan `<repoMemory>` and `<sessionMemory>` blocks in context for all available filenames. Filter by `${input:memoryName}` if set.
2. **List directly via memory tool** — for active scopes, use `memory view /memories/<scope>/` to list available memory files.
3. **Fail closed** — If all probe methods return zero files, report: "No memory files found at scopes `${input:scope}`. Aborting." and stop.

## Read

Read all confirmed memory files and all `.instructions.md` files at the target location.

> **Memory tool availability:** If the `memory` tool is not in the available tool list, call `activate_vs_code_interaction` with no arguments first — it is a one-shot call that permanently unlocks VS Code interaction tools.

1. Read memory files using `memory view /memories/<scope>/<name>.md`.
2. Read all `.instructions.md` files at target: `read_file` each one in full.
3. **Segment each instruction file by section headings** (top-level `##` blocks). Record the heading name and line range for each section.

## Evaluate — assess memory staleness

Break each memory file into atomic facts. For each fact, apply these checks from cheapest to most expensive:

| Signal | Method |
|--------|--------|
| **Codebase contradiction** | Search codebase for the key claim. If current code contradicts it → outdated. |
| **Reference death** | Check referenced files, functions, commands still exist. If any are missing → outdated. |
| **Instruction supersession** | Cross-reference against current `.instructions.md` files. If an instruction already covers the topic and is authoritative → outdated. |
| **Git timestamps** (optional, high cost) | Get memory file timestamp via terminal `ls -l` on the resolved URI (use `resolve_memory_file_uri` — valid because it targets a terminal command, not a memory tool). If memory predates changes to referenced code → likely outdated. |
| **Ambiguous / unverifiable** | Fact cannot be verified or falsified against current workspace → uncertain. |

Verdicts: **current** → absorb, **discard** → remove (provably wrong), **update** → correct then absorb, **ignore** → discard (outdated but harmless), **uncertain** → discard (unverifiable).

### Report before acting

Print evaluation summary with each fact's verdict. Example:

```
memory-foo.md:
  ✅ "run prek for formatting" — current
  ❌ "use build.sh" — discard (file removed)
  🔄 "deploy via rsync" — update (now uses nucleus-apply)
```

## Absorb — cohesive multi-location edits

### Analyze and match

Only facts with verdict **current** or **update** proceed to matching. Facts with verdict **discard**, **ignore**, or **uncertain** are excluded from absorption.

For each qualifying fact, find the best target:

1. **Match by topic keywords** — intersect memory keywords with instruction file names, section headings, and content.
2. **If a fact matches a specific section** → integrate it into that section, within the relevant paragraph or bullet list.
3. **If a fact matches an instruction file but no specific section** → add it as a new subsection or bullet at the logical location within that file.
4. **If a fact spans multiple topics** → split it across multiple instruction files or sections as appropriate.

### Place, don't append

For each matched fact + target section, decide the edit strategy:

- **Existing paragraph matches** → rewrite the paragraph inline to incorporate the fact.
- **Existing bullet list exists** → add a new bullet in the appropriate position (alphabetically or logically).
- **Existing section lacks relevant content** → add a single short paragraph or bullet at the end of the section.
- **No section fits any fact** → as last resort, add a concise section at the end of `core-behavior.instructions.md`.

Do not bulk-append to the end of files unless every other placement was tried and failed.

### Order of edits (critical)

1. First, plan *all* edits across *all* memory files and *all* instruction files in one pass.
2. Group edits by target file.
3. For each target file, order edits bottom-up (last line first) to preserve line numbers.
4. Apply all edits for one file in a single `multi_replace_string_in_file` call.

## Delete

Delete all specified memory files unconditionally. The file has served its purpose — absorbed facts are in the instruction files, and unabsorbed facts (discard/ignore/uncertain) are not worth preserving.

Use `memory delete /memories/<scope>/<name>.md`.

If any edit in the previous step failed, keep the file and report the failure.

## Verify

1. Re-read each modified `.instructions.md` file.
2. Confirm all facts from the original memory are present and accurately expressed.
3. Prune redundancy: if the same fact appears twice in the same file, keep only the better-placed instance.
4. Check voice: the result should read as if the knowledge was always there — no awkward transitions, no verbatim memory dumps.

## Rules

- Prefer modifying existing content over adding new; new bullets over new lists.
- Never verbatim dump memories — rephrase to the target instruction file's voice.
- If a memory is already fully covered, skip it.
- No editorial markers ("Added from memory:", "Note:").
- Delete all specified memory files unconditionally. If any edit in the previous step failed, keep the file and report the failure.
