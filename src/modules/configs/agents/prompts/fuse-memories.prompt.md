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

## Probe harness

Before real work, determine if memory is accessible and how.

1. **Detect memory tools.** Check the current tool list for dedicated memory-capable MCP tools in this order of preference. Stop at the first hit.

   | Priority | Signals memory available | Examples |
   |----------|--------------------------|----------|
   | 1 (dedicated MCP) | A tool named `resolve_memory_file_uri`, `session_store_sql`, or any tool whose description mentions "memory" operations (list/resolve/read/delete) | `resolve_memory_file_uri`, `session_store_sql` (VS Code Copilot Chat) |
   | 2 (generic filesystem) | `read_file`, `list_dir`, `file_search` accessible and able to resolve `/memories/` paths | Tools that can reach `/memories/` paths |
   | 3 (probe path) | `read_file` or `list_dir` succeeds at a canonical memory path | Any toolset where a memory path is reachable |

2. **Fail closed.** If no detection method succeeds, report: "No memory access detected in this agent harness. Aborting." and stop.

## Operation equivalences

From the probe, classify and use these equivalents:

| Tool available | Preferred — dedicated MCP | Fallback — generic |
|----------------|---------------------------|---------------------|
| **List** | `session_store_sql` query on memory metadata, or any dedicated memory list tool | `list_dir` at scope path; `file_search` with glob `**/*.md` |
| **Read** | `resolve_memory_file_uri` to get canonical URI, then `read_file` | `read_file` on canonical path directly |
| **Delete** | Any dedicated memory delete tool if available | `rm "<path>"` (POSIX) / `Remove-Item` (Windows) |

At each workflow step below, attempt the preferred method first. If unavailable in this harness, use the fallback.

## Memory paths

| Scope | Canonical path |
|-------|----------------|
| `session` | `/memories/session/<name>.md` |
| `repo` | `/memories/repo/<name>.md` |
| `user` | `/memories/<name>.md` |

## Workflow

1. **Probe** — Run probe. If no memory access, stop. Record which operation equivalents apply for this harness.

2. **List** — For each scope in `${input:scope}`, list files. Apply `${input:memoryName}` filter if set. Preferred: dedicated MCP list. Fallback: `list_dir` at scope path.

3. **Read** — Read all listed memory files and all `.instructions.md` files at the target location. Preferred: `resolve_memory_file_uri` per file before reading. Fallback: `read_file` on canonical path.

4. **Absorb** — For each memory:
   - Match to the best instruction file by topic keywords.
   - Rewrite existing content to incorporate the facts. If no section fits, append a concise section at the end of `core-behavior.instructions.md`.
   - **Merge, don't append.** Drop redundancy. Keep the target's voice. The result must read as if the knowledge was always there.
   - Apply edits with `replace_string_in_file` or `multi_replace_string_in_file`.

5. **Delete** — Remove each absorbed file. Preferred: dedicated memory delete tool. Fallback: `rm "<resolved-path>"` (POSIX) / `Remove-Item -Path "<resolved-path>"` (Windows). Verify with `[[ ! -f "<path>" ]]` or `!(Test-Path "<path>")`.

6. **Verify** — Re-read modified files. Confirm all facts are present and nothing is verbose. Prune aggressively.

## Rules

- Prefer modifying existing content over adding new; new bullets over new lists.
- Never verbatim dump memories — rephrase to the target instruction file's voice.
- If a memory is already fully covered, skip it.
- No editorial markers ("Added from memory:", "Note:").
- Delete only after all edits succeed. If any edit fails, report the failure and keep the file.
