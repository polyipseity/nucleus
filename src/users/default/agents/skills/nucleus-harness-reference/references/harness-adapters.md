# Harness adapters

Loaded adapter policy stays in the user-scope instruction file. This copy is on demand for capability lookup.

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

## Approval decisions and native rendering

`nucleus-utils harness request-approval` prints one typed decision document on stdout. The typed decision contract has six fields: `version`, `decision`, `reason`, `source`, `timeouts`, and `timedOutSources`. `decision` is `allow`, `deny`, or `ask`. `source` is `prompt`, `hermes`, `all-timeouts`, `resolver-error`, or `none`. Sources default to `["prompt","hermes"]`. Hermes waits 300 seconds and the terminal prompt waits 600 seconds as independent races, so the first answer wins. When both `hermes` and `prompt` time out, the document is a typed `deny` with source `all-timeouts` and reason `all approval sources timed out (hermes 300s, prompt 600s)`. A resolver error is a typed `deny` with source `resolver-error`. The decision is not encoded in stderr.

`nucleus-utils harness decide-call <harness>` renders the typed document in the harness's own vocabulary. Cursor receives `{"permission":"allow"|"ask"|"deny"}`. Claude Code and VS Code Copilot receive `hookSpecificOutput.permissionDecision` with `hookSpecificOutput.permissionDecisionReason` from the typed reason. Pi, OpenCode, Codex, and other harnesses consume the typed document itself. Hooks print one document and exit 0 on every path.

## Hermes profiles and nucleus skills

The local CLI profile uses `~/.hermes/config.yaml`, `~/.hermes/SOUL.md`, `~/.hermes/.env`, and `~/.hermes/skills/`. The gateway profile uses `~/.hermes/profiles/gateway/config.yaml`, `~/.hermes/profiles/gateway/SOUL.md`, `~/.hermes/profiles/gateway/.env`, and `~/.hermes/profiles/gateway/skills/`. Each profile reads its own `.env`. Use `hermes model` for the CLI model picker and `hermes --profile gateway gateway status` for the gateway.

The six nucleus skill bundles live in `src/users/default/agents/skills/<name>/SKILL.md`: `nucleus-citation-reference`, `nucleus-harness-reference`, `nucleus-platform-reference`, `nucleus-policy-reference`, `nucleus-service-reference`, and `nucleus-vm-reference`. Hermes gets relative symlinks at `src/users/default/hermes/skills/<name>` that point at `../../agents/skills/<name>`. On POSIX hosts, apply seeds those bundles into both Hermes profiles.

On Windows, apply writes the gateway autostart to the HKCU Run value `nucleus-hermes-gateway` with the command `hermes --profile gateway gateway run --replace`. Log off and on after a command change.
