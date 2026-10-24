---
description: "Reference: capability names to concrete harness tools, agents, and directories. Read when a prompt or instruction names a capability and the running harness is unknown."
name: "Harness Adapters"
---

# Harness adapters

Prompt bodies name capabilities, never one harness's surface. Resolve each capability here for the harness that is running. When a capability is unmapped for the current harness, say so and stop; do not guess a tool name and do not quietly map one scope onto another.

| Capability | Pi | VS Code Copilot |
| --- | --- | --- |
| Session memory | directory `~/.pi/agent/memory/session`, read and written with `read`, `write`, and `bash`; no dedicated tool | `memory` tool `view`, `create`, `str_replace`, `delete`; `/memories/session/` |
| Repo memory | none | `/memories/repo/` |
| Durable memory | `memory_write`, `memory_read`, `memory_search`, `scratchpad` (`MEMORY.md`, `daily/`, `SCRATCHPAD.md`) | `memory` tool on the `/memories/` root |
| Child agent | `subagent` tool | `runSubagent` |
| Research agent (read-only recon) | `scout`, or `reviewer` when the child must not write at all | `Explore` |
| Implementation agent | `worker` | `General Purpose` |
| Review agent | `reviewer` (no edit or write tools) | `code-review` |
| File edit | `edit`, `write` | `replace_string_in_file`, `multi_replace_string_in_file`, `create_file` |
| Shell | `bash` | `run_in_terminal` |
| Skill | `/skill:<name>`, or read the `SKILL.md` | `skill:` invocation, or read the `SKILL.md` |
| Read-only mode | `/plan` blocks `edit`, `write`, and unsafe bash | no harness mode; obey the standing orders boundary |
| Model pin | `subagents.modelScope` in settings, allow `inherit` only | model picker; the owner's choice is the only authority |

`scout` ships `write` for its `context.md` artifact, so it is not a read-only child. Use `reviewer` when the boundary forbids any write.

opencode, Cursor, and CLI agents have no verified mapping in this repository. State the gap and use repository files instead of an unverified tool name.

## Prompt invocation names

Pi derives the command name from the filename, so `commit-staged.prompt.md` is invoked as `/commit-staged.prompt`. The suffix is load-bearing: Cursor's sync maps `*.prompt.md` to `*.md` commands. Quote the full command name when telling the owner how to invoke a workflow.
