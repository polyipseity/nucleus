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

## Evaluate — assess memory staleness

Before absorbing, evaluate each atomic fact for staleness. Break each memory file into atomic facts (paragraph-level or bullet-level claims). For each fact, apply these checks from cheapest to most expensive:

### Staleness indicators

| Signal | Method | Example |
|--------|--------|--------|
| **Codebase contradiction** | Search the codebase (`grep_search`, `file_search`) for the key claim. If current code contradicts it → **outdated**. | Memory says "activation runs via `apply.sh`" but the file was renamed. |
| **Reference death** | Check that files, functions, commands, or config keys referenced in the fact still exist. If any are missing → **outdated**. | Memory says "see `src/modules/foo.nix`" but that file was deleted. |
| **Instruction supersession** | Cross-reference against current `.instructions.md` files. If an instruction already covers the topic differently and is authoritative → **outdated**. | Memory says "use `nix build`" but `core-behavior.instructions.md` says "use `nix build .#target`". |
| **Git timestamps** (optional, high cost) | Get the memory file timestamp via `git log -1 --format=%ct <memory_path>`. If the memory predates significant changes to referenced code, likely **outdated**. Corroborate with other signals. | Memory is 6 months old; referenced code was refactored 3 months ago. |
| **Ambiguous / unverifiable** | Fact cannot be verified or falsified against current workspace. Mark as **uncertain**. | Memory says "prefer TCP over UDP" with no supporting code to check. |

### Verdicts

| Verdict | Meaning | Action |
|---------|---------|--------|
| **current** | Fact matches current codebase state and isn't superseded. | Proceed to **Absorb** normally. |
| **discard** | Fact is provably wrong or references removed features. | Remove from memory file; do **not** absorb. |
| **update** | Useful core but expressed inaccurately for current state. | Correct the fact inline in memory, then proceed to **Absorb** with corrected version. |
| **ignore** | Outdated but harmless, and you cannot confidently update it. | Discard; do **not** absorb (file will be deleted). |
| **uncertain** | Cannot determine staleness with available evidence. | Discard; do **not** absorb (file will be deleted, no source to reference). |

### Report before acting

Print an evaluation summary after processing all facts:

```
Evaluation summary:
  memory-foo.md:
    ✅ "run prek for formatting" — current
    ❌ "use build.sh" — discard (file removed)
    🔄 "deploy via rsync" — update (now uses nucleus-apply)
    ⚠️ "use port 8080" — ignore (harmless, can't verify)
    ❓ "prefer UDP" — uncertain, discarding (file will be deleted)
  memory-bar.md:
    ... etc
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

### Examples of good vs. poor absorption

Good: Memory says "prek run --all-files before commit". Instruction file has a "Validation" section with a bullet list of commands. Add the prek command as a new bullet in that list.

Poor: Memory says "prek run --all-files before commit". Appended to end of `core-behavior.instructions.md` as a new section.

Good: Memory says "macOS watchdog daemon: use `launchctl bootout` then `launchctl bootstrap` to reload". Instruction file `spotlight-disable.instructions.md` has a section on "Disable spotlight" already. Add the reload pattern inline to the relevant step.

Poor: Memory says "macOS watchdog daemon: use launchctl to reload". Appended verbatim to end of file.

## Delete

Delete all specified memory files unconditionally. The file has served its purpose — absorbed facts are in the instruction files, and unabsorbed facts (discard/ignore/uncertain) are not worth preserving.

Use the resolved URI from Step 2 (preferred). Fallback:

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
- Delete all specified memory files unconditionally. If any edit in the previous step failed, keep the file and report the failure.
