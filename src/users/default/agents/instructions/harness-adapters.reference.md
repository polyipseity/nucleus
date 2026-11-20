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

The machine-checked capability matrix is `src/modules/configs/harness-capabilities.json` (schema `harness-capabilities.schema.json`); truthfulness rules are enforced by `tests/scripts/harness-capability-truth-tests.sh`.


Commands and modes, where implemented: `/continue`, `/copy-user-prompt [sent|queued|pick]`, `/repeat-user-prompt [sent|queued|pick]` (default `sent`). `pick` resolves by the harness-specific implementation described below; cancel/empty states are one-line/no-op as implemented.

| Harness | Status | Implementation / evidence | Notes |
| --- | --- | --- | --- |
| Pi | Implemented | `src/users/default/pi/extensions/prompt-tools.ts` (unit-tested). | `sent` = last user-role message in the session branch; `queued` = newest prompt in `<nucleus user root>/state/harness-bridge/commands/pi/*.json` (read without consuming). Picker uses TUI selection per implementation. |
| OpenCode v2 | Implemented (minimum `@opencode/cli` / plugin contract 2.3.0) | TUI plugin `src/users/default/opencode/plugins/prompt-tools/tui.js` (seeded/wired by `src/modules/agents.nix`, `src/users/default/opencode/opencode.jsonc`; bun tests `tests/users/default/opencode/plugins/prompt-tools.test.ts`). v2 contract: `.superpowers/sdd/plan/reports/opencode-v2-contract.md`. | `sent` from session message list, `queued` from pending/bridge queue per implementation; clipboard exec with visible fallback. Live v2 TUI runtime verification may be environment-limited; no silent no-op commands. |
| Claude Code | Implemented (mod; minimum CLI version recorded for provisioning: winget/lock `Anthropic.ClaudeCode` 2.1.318, npm 2.1.325 observed during planning) | Mod `src/users/default/claude/plugins/nucleus-prompt-tools/` (`.claude-plugin/plugin.json`, `hooks/hooks.json` modules `./register.js`, `hooks/register.js`; tests `tests/users/default/claude/plugins/prompt-tools.test.ts`), enabled via `src/users/default/claude/settings.json` `extraKnownMarketplaces`/`enabledPlugins` and deployed with marketplace/plugin by POSIX `src/modules/shell/default.nix` and Windows `src/platforms/Windows/modules/user/Sync-ClaudeConfig.ps1`. | `pick` is deterministic (queued if present, else sent): no verified mod dialog/picker API was found in available docs/repo evidence (see `.superpowers/sdd/plan-2026-11-16T173103-deferrals/reports/C1-report.md`), so no picker UI is claimed. `sent` detection is best-effort across runtime shapes. `/continue` assumes harness queueing while busy and needs one on-host check on a machine with the Claude CLI. |
| Cursor | Verdict: not implementable (K3) | Artifacts: `src/users/default/cursor/hooks.json` (harness-filter/harness-drive hooks only); `src/scripts/configs/symlink-cursor-config.sh` maps `src/users/default/agents/prompts/*.prompt.md` to `~/.cursor/commands/*.md` (prompt-only surface). | Rejected by ruling R6/R9: prompt files are not an acceptable command mechanism. Not an oversight. |
| VS Code Copilot | Verdict: not implementable (K3) | Artifacts: `src/users/default/agents/hooks/harness-notify.json` (PreToolUse/Stop hooks only). VS Code chat participant API is deprecated and unsupported in the Copilot harness; prompt-file surfaces are the same excluded mechanism. | Rejected by ruling R6/R9: prompt files are not an acceptable command mechanism. Not an oversight. |
| Hermes | Implemented (queued-only copy prompt) | Plugin command `/harness prompts [index]` in `src/users/default/hermes/plugins/harness-bridge/__init__.py` (unit-tested); copies selected queued prompt via `harness-clipboard`. | Numbered reverse-chronological list of queued prompts only; sent history unavailable because the plugin API exposes no message history. No queue consumption; no `continue` or `repeat-user-prompt` command. |

## Prompt invocation names

Pi derives the command name from the filename, so `commit-staged.prompt.md` is invoked as `/commit-staged.prompt`. The suffix is load-bearing: Cursor's sync maps `*.prompt.md` to `*.md` commands. Quote the full command name when telling the owner how to invoke a workflow.

## Sandbox context change notice (`nucleus-utils sandbox-context`)

`nucleus-utils sandbox-context <harness> [--format <text|claude|cursor|check>] [--session-id <id>]` records per-harness, per-session sandbox state under `<USER root>/state/harness-bridge/sandbox/<harness>.json` and emits context on the first observation or a sandboxed/unsandboxed transition. Injection is gated by `sandbox-context.inject-on-change` (default `true`); when off, the record still advances but nothing is emitted.

| Harness | Injection hook | Recording | Notes |
| --- | --- | --- | --- |
| Pi | `context` event in `src/users/default/pi/extensions/sandbox-context.ts` when the last message is a user message (`--format text`) | Yes | Session id defaults to `default` when unavailable. |
| Claude Code | `UserPromptSubmit` hook in `src/users/default/claude/settings.json` (`--format claude`, `hookSpecificOutput.additionalContext`) | Yes | Wired per the specified Claude Code UserPromptSubmit hook output format; external protocol documentation could not be fetched in this environment. |
| Cursor | None wired | Yes, via `harness-filter`/`harness-drive` side effects (`--format check`) | `beforeSubmitPrompt` prompt-visible context injection protocol was not verified, so no prompt-injection hook is wired and `--format cursor` records without emitting. Missing prompt-injection hook: a verified `beforeSubmitPrompt` (or equivalent) context-injection protocol. |
| VS Code Copilot | None | Yes, via `harness-filter`/`harness-drive` side effects (`--format check`) | No prompt-submission context-injection hook is available in the configured hook set (`PreToolUse`/`Stop` only). Missing hook: a prompt-submission context-injection hook. |
| OpenCode | None wired | Yes, via `harness-filter`/`harness-drive` side effects where applicable (`--format check`) | Prompt-visible context injection hook not verified for the v2 plugin contract in this environment; record-only. |
| Hermes | None | Record-only gap documented | No prompt-submission hook for injecting prompt-visible context into Hermes conversations. Missing hook: a prompt-submission context-injection hook. |
