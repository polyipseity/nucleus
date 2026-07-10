---
name: fuse-memories
description: "Use when: user says 'absorb memories', 'fuse memories', 'merge memories into instructions', or asks to persist session/repo/user memory into agent instructions. Merges selected memory files into repo or user .instructions.md files and deletes the originals."
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

Memory storage is not a flat filesystem — `list_dir` on canonical paths typically fails (ENOENT) or returns empty due to UUID-keyed subdirectory layout. Do not rely on filesystem listing.

### Step 1: Check context metadata (fastest, most reliable)

The agent's context already contains `<repoMemory>` and `<sessionMemory>` blocks that list all available filenames. Scan those directly.

If `${input:memoryName}` is set, filter to only those names. Otherwise collect all names from the matching scopes.

### Step 2: Confirm each file exists via resolve_memory_file_uri

For each candidate filename, call `resolve_memory_file_uri("/memories/<scope>/<name>.md")`. If it returns a valid URI, the file exists. Collect the resolved URIs for reading.

### Step 3: Explicit probe fallback chain

If context metadata is unavailable (no `<repoMemory>`/`<sessionMemory>` blocks in context):

1. **Best**: `session_store_sql` — query `SELECT DISTINCT filename FROM memory_index` or equivalent.
2. **Fallback**: For each scope, call `resolve_memory_file_uri("/memories/<scope>/")` to get the base directory URI, then use the resolved path with `list_dir` or `file_search` with glob `**/*.md` at that path.
3. **Last resort**: Probe known names directly with `resolve_memory_file_uri("/memories/<scope>/<name>.md")` for each expected file.

### Fail closed

If all probe methods return zero files, report: "No memory files found at scopes `${input:scope}`. Aborting." and stop.

## Read

Read all confirmed memory files and all `.instructions.md` files at the target location.

1. Read memory files using the URIs from Step 2 (or `read_file` on canonical path if resolve failed but file is known).
2. Read all `.instructions.md` files at target: `read_file` each one in full.
3. **Segment each instruction file by section headings** (top-level `##` blocks). Record the heading name and line range for each section.

## Absorb — cohesive multi-location edits

### Analyze and match

For each memory file, extract its key facts/paragraphs. For each fact, find the best target:

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

### Examples of good vs. poor absorption

Good: Memory says "prek run --all-files before commit". Instruction file has a "Validation" section with a bullet list of commands. Add the prek command as a new bullet in that list.

Poor: Memory says "prek run --all-files before commit". Appended to end of `core-behavior.instructions.md` as a new section.

Good: Memory says "macOS watchdog daemon: use `launchctl bootout` then `launchctl bootstrap` to reload". Instruction file `spotlight-disable.instructions.md` has a section on "Disable spotlight" already. Add the reload pattern inline to the relevant step.

Poor: Memory says "macOS watchdog daemon: use launchctl to reload". Appended verbatim to end of file.

## Delete

Remove each absorbed memory file. Use the resolved URI from Step 2 (preferred). Fallback:

- POSIX: `rm "<resolved-path>"`
- Windows: `Remove-Item -Path "<resolved-path>"`

Verify with `[[ ! -f "<resolved-path>" ]]` or `!(Test-Path "<resolved-path>")`.

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
- Delete only after all edits succeed. If any edit fails, report the failure and keep the file.
