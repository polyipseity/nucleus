---
description: "Reference: capability names to concrete harness tools, agents, and directories. Read when a prompt or instruction names a capability and the running harness is unknown."
name: "Harness Adapters"
---

# Harness adapters

Prompt bodies name capabilities, never one harness's surface. Resolve each capability here for the harness that is running. When a capability is unmapped for the current harness, say so and stop; do not guess a tool name and do not quietly map one scope onto another.

This file is user scope, deployed to `~/.agents/instructions/`, so it applies in every repository; rules that belong to one repository stay in that repository's `.agents/instructions/`.

| Capability | Pi | VS Code Copilot |
| --- | --- | --- |
| Session memory | directory `~/.pi/agent/memory/session`; one file per entry, named by the workflow | `/memories/session/` |
| Memory operations | `memory_write`, `memory_read`, and `memory_search` when the extension is installed; its entries are plain files under the directory above, so file tools read and write the same store | the memory API (`view`, `create`, `str_replace`, `delete`, `rename`) with `/memories/` paths; file tools must not drive it |
| Repo memory | none | `/memories/repo/` |
| Durable memory | `memory_write`, `memory_read`, `memory_search`, `scratchpad` (`MEMORY.md`, `daily/`, `SCRATCHPAD.md`) | `memory` tool on the `/memories/` root |
| Child agent | `subagent` tool | `runSubagent` |
| Research child (read-only recon) | `scout`, or `reviewer` when the child must not write at all | `Explore` |
| Implementation child | `worker` | `General Purpose` |
| Review child | `reviewer` (no edit or write tools) | `code-review` |
| Diagnostics after an edit | none built in, so rely on the compiler, linter, or test command | `get_errors` after each editing round |
| Batch edit | `edit` with several replacements in one call | `multi_replace_string_in_file` |
| File edit | `edit`, `write` | `replace_string_in_file`, `multi_replace_string_in_file`, `create_file` |
| Shell | `bash` | `run_in_terminal` |
| Skill | `/skill:<name>`, or read the `SKILL.md` | `skill:` invocation, or read the `SKILL.md` |
| Read-only mode | `/plan` blocks `edit`, `write`, and unsafe bash | no harness mode; obey the standing orders boundary |
| Model pin | `subagents.modelScope` in settings, allow `inherit` only | model picker; the owner's choice is the only authority |
| Continue turn | `/continue` (prompt-tools extension; falls back to `sendUserMessage(" ")` when no retry/resume API is verified) | no verified command surface in this repository; use harness-native controls if available, otherwise state the gap |
| Copy user prompt | `/copy-user-prompt [sent\|queued\|pick]` (default `sent`; clipboard exec with selectable-text fallback) | no verified command/history/clipboard surface in this repository; state the gap |
| Repeat user prompt | `/repeat-user-prompt [sent\|queued\|pick]` (default `sent`; confirms while streaming, resubmits as a new user turn) | no verified command/history/resubmit surface in this repository; state the gap |

`scout` ships `write` for its `context.md` artifact, so it is not a read-only child. Use `reviewer` when the boundary forbids any write.

A session-memory entry is one file whose name the workflow chooses, so `plan-<datetime>.md` and `checkpoint-<datetime>.md` are the same filename on every harness and only the directory above differs.

opencode, Cursor, Claude Code, Hermes, and CLI agents have no verified mapping for most capabilities in this repository. State the gap and use repository files instead of an unverified tool name.

Prompt tools (verified/unsupported): Pi implements `/continue`, `/copy-user-prompt [sent|queued|pick]`, and `/repeat-user-prompt [sent|queued|pick]` via `src/users/default/pi/extensions/prompt-tools.ts` (unit-tested). `sent` is the last user-role message in the session branch; `queued` is the newest prompt in `<nucleus user root>/state/harness-bridge/commands/pi/*.json` (read without consuming). OpenCode, Cursor, VS Code Copilot, Claude Code, and Hermes do not have verified custom-command surfaces for equivalent copy/repeat/continue behavior in this repository; Hermes continues to support manual queued resend via `/harness send` where available. Do not register silent no-op commands for unsupported harnesses.

## Prompt invocation names

Pi derives the command name from the filename, so `commit-staged.prompt.md` is invoked as `/commit-staged.prompt`. The suffix is load-bearing: Cursor's sync maps `*.prompt.md` to `*.md` commands. Quote the full command name when telling the owner how to invoke a workflow.
