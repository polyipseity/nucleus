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

## Prompt tools capability (continue / copy user prompt / repeat user prompt)

Commands and modes, where implemented: `/continue`, `/copy-user-prompt [sent|queued|pick]`, `/repeat-user-prompt [sent|queued|pick]` (default `sent`). `pick` resolves by the harness-specific implementation described below; cancel/empty states are one-line/no-op as implemented.

| Harness | Status | Implementation / evidence | Notes |
| --- | --- | --- | --- |
| Pi | Implemented | `src/users/default/pi/extensions/prompt-tools.ts` (unit-tested). | `sent` = last user-role message in the session branch; `queued` = newest prompt in `<nucleus user root>/state/harness-bridge/commands/pi/*.json` (read without consuming). Picker uses TUI selection per implementation. |
| OpenCode v2 | Implemented (minimum `@opencode/cli` / plugin contract 2.3.0) | TUI plugin `src/users/default/opencode/plugins/prompt-tools/tui.js` (seeded/wired by `src/modules/agents.nix`, `src/users/default/opencode/opencode.jsonc`; bun tests `tests/users/default/opencode/plugins/prompt-tools.test.ts`). v2 contract: `.superpowers/sdd/plan/reports/opencode-v2-contract.md`. | `sent` from session message list, `queued` from pending/bridge queue per implementation; clipboard exec with visible fallback. Live v2 TUI runtime verification may be environment-limited; no silent no-op commands. |
| Claude Code | Implemented (mod; minimum CLI version recorded for provisioning: winget/lock `Anthropic.ClaudeCode` 2.1.318, npm 2.1.325 observed during planning) | Mod `src/users/default/claude/plugins/nucleus-prompt-tools/` (`.claude-plugin/plugin.json`, `hooks/hooks.json` modules `./register.js`, `hooks/register.js`; tests `tests/users/default/claude/plugins/prompt-tools.test.ts`), enabled via `src/users/default/claude/settings.json` `extraKnownMarketplaces`/`enabledPlugins` and deployed with marketplace/plugin by POSIX `src/modules/shell/default.nix` and Windows `src/platforms/Windows/modules/user/Sync-ClaudeConfig.ps1`. | `pick` is deterministic (queued if present, else sent): no verified mod dialog/picker API was found in available docs/repo evidence (see `.superpowers/sdd/plan-2026-11-16T173103-deferrals/reports/C1-report.md`), so no picker UI is claimed. `sent`/busy detection are best-effort across runtime shapes. |
| Cursor | Verdict: not implementable (K3) | Artifacts: `src/users/default/cursor/hooks.json` (harness-filter/harness-drive hooks only); `src/scripts/configs/symlink-cursor-config.sh` maps `src/users/default/agents/prompts/*.prompt.md` to `~/.cursor/commands/*.md` (prompt-only surface). | Rejected by ruling R6/R9: prompt files are not an acceptable command mechanism. Not an oversight. |
| VS Code Copilot | Verdict: not implementable (K3) | Artifacts: `src/users/default/agents/hooks/harness-notify.json` (PreToolUse/Stop hooks only). VS Code chat participant API is deprecated and unsupported in the Copilot harness; prompt-file surfaces are the same excluded mechanism. | Rejected by ruling R6/R9: prompt files are not an acceptable command mechanism. Not an oversight. |
| Hermes | Control plane only | Bridge/control-plane integration (`/harness send` where available). | No prompt-tools command surface; do not register silent no-op commands. |

## Prompt invocation names

Pi derives the command name from the filename, so `commit-staged.prompt.md` is invoked as `/commit-staged.prompt`. The suffix is load-bearing: Cursor's sync maps `*.prompt.md` to `*.md` commands. Quote the full command name when telling the owner how to invoke a workflow.
