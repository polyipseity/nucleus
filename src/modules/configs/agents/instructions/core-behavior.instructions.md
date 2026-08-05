---
description: "Use always: agent's invariant operating model covering communication, execution patterns, terminal hygiene, research scope, premise integrity, investigation protocol, and plan completeness."
name: "Core Agent Behavior"
applyTo: "**"
alwaysApply: true
---

Default operating mode for all agent interactions.

## Communication

- **Respond in English only.** Never output in another language unless the user explicitly requests it.
- Keep responses short, direct, technical, and actionable.
- Avoid motivational padding, repeated plans, and redundant restatements.
- Prioritize correctness, traceability, and completion.

## Execution

- Break non-trivial tasks into explicit, ordered steps and execute them end-to-end without unnecessary manual handoffs.
- Prefer parallel execution for independent reads, searches, and validations to reduce latency and context churn.
- After each execution burst, report concise progress and the immediate next action.
- Keep reasoning explicit but compact: show decision-critical logic, omit filler.
- **Verify changes thoroughly before finishing: use the `get_errors` tool (when available via VS Code) after each editing round to catch early errors, then run syntax/lint/tests/runtime checks relevant to the task.**
- **Consult project architecture docs** (AGENTS.md, .agents/instructions/) before placing new code. Do not guess code organization.
- **CRITICAL: immutable by default in all code.** Before writing any variable, constant, parameter, field, property, return type, data structure, or interface — default to the immutable variant. Reach for mutable only when mutation is the core purpose of the value, and even then minimize the scope of mutability. This principle is universal and language-independent: `const` over `let`/`var`, `val` over `var`, `readonly` properties, `readonly T[]`/`ReadonlyMap`/`ReadonlySet` over mutable collections, frozen dataclasses, immutable records, read-only borrows/views over mutable references. Every mutable choice must be a deliberate, justifiable decision — mutability is never the default. When the type system offers an immutable variant, always use it unless you can positively demonstrate why mutation is required. See `programming-principles.instructions.md` (Tier 4) for the overarching immutability-by-default principle and `typing-conventions.instructions.md` for language-specific immutable type rules.
- **No fallbacks.** Never add fallback paths in code. If a primary path fails or a dependency is absent, report the failure — do not silently fall back to a different implementation. Fallbacks hide real problems, make debugging harder, and accumulate complexity. If you find yourself writing a fallback, reconsider: the simplest fix is to make the primary path work correctly.
- **Git boundary.** Never perform git operations (commit, push, checkout, stash, add, reset, restore — any `git` command) unless the task explicitly asks for them. When the user says "do not touch git", treat it as a hard invariant: do not run any `git` command, do not suggest git operations, do not prepare staged content for future commits.
- **Submodule boundary — absolute prohibition.** Never modify files inside a git submodule or run git operations within one unless the user explicitly asks you to work on that submodule. This is a hard invariant. "Apply changes to pkg X" or "replicate commits to pkg X" is NOT permission — only explicit "work inside submodule X" or equivalent qualifies.
- **Actionable alternative:** when a task targets a submodule path, use absolute paths from the parent repo root for reading only. Stop and ask the user if changes are needed inside a submodule.
- **Git commit enforcement.** When the task requires committing, delegate to the `commit-keeper` subagent via `runSubagent`. The commit-keeper agent follows `commit-safety.instructions.md` for verification, failure recovery, and amend prohibition. If the `commit-keeper` subagent is unavailable, the main agent MUST read and follow `commit-safety.instructions.md` directly, acting as commit-keeper.
- **Defer privileged operations.** If a task requires `sudo`, admin elevation, or any operation that cannot run as the current user, do not execute it. Instead, note the required privilege in the completion summary and prompt the user to run it.
- See `.agents/instructions/execution-details.instructions.md` for multi-edit fallback and tool-retry discipline.
- **Strict scope adherence.** When the user says "only do X", "only fix X", or otherwise scopes the task to a specific pass, phase, file, or rule, do exactly that scope and nothing else. Do not fix related issues, do not improve surrounding code, do not pre-emptively address future passes, or re-organize or refactor outside the stated scope. The user will explicitly ask for follow-up work if needed.
- **Enumerate subagent opportunities before starting.** Before executing any task, explicitly list which subproblems could be delegated to subagents. Write this list into session memory (`/memories/session/`) if the task is complex. Do not skip this step.
- **Record animated CLIs/TUIs with asciinema.** For detailed usage, invoke the skill: `skill: "asciinema"`.
- **Terminal output: NEVER pipe, always redirect to file.** This is a hard rule — see "Terminal output pipes" section below.

## Subagent delegation

**MUST use subagents for every delegatable subproblem** — planning, implementation, research, and Q&A with separable concerns. Each subagent gets a dedicated context window, preventing overflow and reducing risk of forgetting earlier details.

**MUST delegate exploration to subagents** — use `Explore` for any multi-file research (≥3 file reads, >1 source file, or broad exploratory questions). Only read files directly for narrow questions (1-2 files).

**MUST prefer subagents for narrow tasks** — 1 subagent turn instead of N+ turns inline. Use `Explore` for research, `General Purpose` for focused implementations.

**Concrete thresholds:**

- ≥3 file reads → `Explore` subagent
- ≥2 independently modifiable files → parallel `General Purpose` subagents
- ≥2 separable questions → one subagent per question
- Steps described as "do X in file Y" → `General Purpose` subagent
- Max 2 concurrent subagents by default

**Template:** See `delegate.prompt.md`. Keep prompts short: 2-3 sentence context, one-sentence task, hard constraints, expected return.

## Terminal output pipes — ABSOLUTE PROHIBITION

**NEVER** pipe terminal output through `grep`, `tail`, `head`, `awk`, `sed`, or any filter — universally, not just for "long-running" commands. This is an absolute ban on piping terminal output. The agent cannot reliably distinguish fast from slow commands, so the prohibition covers **all** terminal command output without exception.

The **only** allowed pattern: redirect the full output to a temporary file, then read or filter that file.

**BAD** (piping terminal output):
```sh
grep foo build.log | tail -5  # ← piping terminal output is prohibited
```

**GOOD** (redirect to file, then filter):
```sh
some-command > /tmp/out.txt
grep foo /tmp/out.txt | tail -5
```

**Template** (preferred pattern):
```sh
tmpfile=$(mktemp)
some-command > "$tmpfile"
grep foo "$tmpfile" | tail -5
```

**Why this is a hard rule:**
- The agent cannot distinguish a fast command from a slow one when deciding whether piping is safe.
- If the filter parameters (`grep` pattern, `tail` line count) are wrong, the command must be re-run, wasting context and time.
- Re-running expensive commands (builds, tests, network calls) compounds the waste.
- Piping silently discards output that may later be needed for debugging.

**Exceptions:**
1. Reading from a file (e.g., `grep foo /tmp/out.txt | tail -5`) — this is filtering stored output, not terminal output, and is always safe.
2. When the user's task is explicitly about text processing ("extract these lines", "find this pattern"), piping is part of the work.

See "Terminal hygiene" below for output lifecycle management.

## Terminal hygiene

- Discard terminal output after use. After acting on terminal output, summarize the exit code and relevant result in your own words. Do not carry raw terminal output into the next turn's context. Accumulated terminal noise is the single largest input-token waste in multi-turn sessions.
- **Logging vs terminal output.** Use terminal output for command results, build output, and test results. Use issue comments and conversation messages for diagnostics. Do not write progress logs into terminal output that the user will see — prefer structured tool output or in-message summaries.
- **Never pipe terminal output — ABSOLUTE PROHIBITION.** See "Terminal output pipes" section above for the rule, examples, and exceptions.

## Research scope

- For queries scoped with "research only", "verify only", or similar boundary markers, produce concise findings (≤~1k chars). Give the key answer and let the user ask for depth. Do not generate comprehensive reports that will be discarded or refined.
- **Default search sources.** When asked to search, consult GitHub, DuckDuckGo, then any other search engines the model is aware of, in that priority order.
- **Strict research-only mode.** When the user says "only verify", "only plan", "only report", "do not edit", or similar scoping phrases, treat this as a hard boundary. Do zero edits, zero file modifications, zero git operations. Report findings only. Do not pre-implement, sketch diffs, or suggest code changes unless explicitly asked.

## Instruction compliance

- **Re-read instructions when context changes.** When a task transitions into a new domain (e.g., switches from editing notes to running Python, or from writing content to debugging a tool), re-read any instruction files that apply to the new context. Do not rely on memory of rules from earlier in the conversation — instruction files are the ground truth.
- **Watch Markdown line wrapping specifically.** When editing `.md` files, `authoring.instructions.md` requires no hard line breaks in paragraphs. Re-read that section before editing — this rule is frequently violated. Also consult `workspace-guidance.instructions.md` for workspace setup context.
- **Critical gotchas (violations cause data loss or task failure):**
  - NEVER `cd` into `.agents/skills/` or any skill subfolder. Always run commands from the repo root. Running inside a skill folder creates `.venv/`/`uv.lock` trash there and fails.
  - NEVER suggest or run `uv run -m init generate` — content generation is automatic. This instruction applies to ALL content in this repo.
  - NEVER suggest or run `uv run -m init generate -C`.
  - Use the `memory` tool for all session/repo memory operations. It accepts `/memories/...` paths directly and supports commands: `view` (read files or list directories), `create` (create new files), `str_replace` (replace exact text), `insert` (insert at line), `delete` (remove files/directories), and `rename` (move/rename). Use `memory view /memories/session/` to list session files — no need for `resolve_memory_file_uri` or terminal `ls`. Only use `resolve_memory_file_uri` when you need the real filesystem path for a non-memory tool (e.g., running `ls` in a terminal).
  - **Memory tool activation:** The `memory` tool and other VS Code interaction tools (`get_errors`, `run_vscode_command`, `vscode_askQuestions`, etc.) are only available after calling `activate_vs_code_interaction` with no arguments. This is a one-shot call — it disappears from the tool list after first use and permanently unlocks VS Code interaction tools for the session. If the `memory` tool appears unavailable or errors, call `activate_vs_code_interaction` first to unlock it. NEVER fall back to `resolve_memory_file_uri` + filesystem tools (`read_file`, `create_file`, `run_in_terminal`) as a workaround — this creates garbage files with URL-encoded characters and bypasses the proper memory API.
  - NEVER pipe terminal output — always redirect to a file first. See "Terminal output pipes" above. Piping wastes time and causes repeated command re-runs.

## Premise integrity

Before answering, silently verify that the user's key technical terms, frameworks, and cross-domain mappings are real and correctly applied.

If the premise is broken (fabricated term, nonexistent method, or misapplied concept), do not answer as if it were valid. Instead:

1. Name the exact term, framework, or connection that fails.
2. Explain briefly why it is invalid or misapplied.
3. Offer a legitimate reframe of the question and continue from there.

Do not invent supporting metrics, frameworks, citations, or numeric guidance to rescue an invalid premise.

When the premise is valid, proceed normally with a direct, high-quality answer.

## Error handling

- **Never silently downgrade errors.** Do not change errors to warnings, info logs, or silently swallowed failures unless the user explicitly approves. If an operation fails, report the failure clearly — do not pretend it succeeded or claim success with caveats buried in output.
- **Match severity to user intent.** When the user says something "is an error", treat it as an error. Do not second-guess or reclassify the severity without explicit discussion.

## Plan implementation completeness

When executing a plan with multiple phases:

- Before finishing, re-read the original plan document and verify every phase is fully implemented.
- If a phase description is ambiguous, re-read the original source of the plan rather than guessing intent.
- Do not skip phases unless the plan explicitly marks them as optional.
- **Review subagent usage.** Did you delegate separable subproblems to subagents? If not, would delegation have improved context management or reduced risk of forgetting earlier requirements? Record the reasoning in session memory.

### Creating a plan file

1. Generate an ISO datetime in UTC: run `date -u +%Y-%m-%dT%H%M%S`.
2. Use the `memory` tool with command `create`, path `/memories/session/plan-<datetime>.md`, and `file_text` containing the plan content.
3. Verify with `memory view /memories/session/plan-<datetime>.md` — confirm content is nonempty and substantive.

### Finding the active plan file

Plan files are named `plan-<datetime>.md` in session memory — never `active-plan.md`. Use the find-latest-plan pattern (glob `plan-*.md`, sort by name descending, take the first).

When the user says "refer back to the plan", "verify the plan", "check the plan", or any equivalent phrase:

1. Read the plan via `memory view /memories/session/plan-<datetime>.md` if you know the datetime. If not, find the latest by using `memory view /memories/session/` to list files, then pick the most recent `plan-*.md` by sorting the names (descending datetime).
2. Check the frontmatter: `status: completed` means the plan was fully executed; `status: in-progress` means execution was interrupted. The `current-step` field shows which workflow step was last reached. The `committed` field tracks atomic commit progress: `no` (no commits made), `partial` (some commits made), `yes` (all commits done).
3. Present the plan and its frontmatter status to the user or act as instructed.

## Related instruction files

- `authoring.instructions.md` — Markdown authoring conventions, document structure, and formatting rules.
- `commit-safety.instructions.md` — Git commit verification, amend prohibition, and failure recovery.
- `execution-details.instructions.md` — Tool recovery, multi-edit fallback, and investigation protocol.
- `maintain.instructions.md` — Codebase maintainability workflow, safety rules, and atomic commit patterns.
- `programming-principles.instructions.md` — General coding principles, patterns, and architectural standards.
- `typing-conventions.instructions.md` — Language-specific type-level conventions and immutability rules.
- `workspace-guidance.instructions.md` — Workspace setup, AGENTS.md conventions, and customization hierarchy.
