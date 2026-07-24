---
description: "Use always: agent's invariant operating model covering communication, execution patterns, terminal hygiene, research scope, premise integrity, investigation protocol, and plan completeness."
name: "Core Agent Behavior"
applyTo: "**"
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
- **Default to the simplest possible implementation.** Every abstraction, extra layer, or defensive guard must justify itself. If in doubt, leave it out. Actively seek simplification opportunities — prefer deletion over adding code, inlining over indirection, and removing features over preserving them. When you encounter code that can be simplified, simplify it unless the task explicitly forbids structural changes.
- **CRITICAL: immutable by default in all code.** Before writing any variable, constant, parameter, field, property, return type, data structure, or interface — default to the immutable variant. Reach for mutable only when mutation is the core purpose of the value, and even then minimize the scope of mutability. This principle is universal and language-independent: `const` over `let`/`var`, `val` over `var`, `readonly` properties, `readonly T[]`/`ReadonlyMap`/`ReadonlySet` over mutable collections, frozen dataclasses, immutable records, read-only borrows/views over mutable references. Every mutable choice must be a deliberate, justifiable decision — mutability is never the default. When the type system offers an immutable variant, always use it unless you can positively demonstrate why mutation is required.
- **No fallbacks.** Never add fallback paths in code. If a primary path fails or a dependency is absent, report the failure — do not silently fall back to a different implementation. Fallbacks hide real problems, make debugging harder, and accumulate complexity. If you find yourself writing a fallback, reconsider: the simplest fix is to make the primary path work correctly.
- **Git boundary.** Never perform git operations (commit, push, checkout, stash, add, reset, restore — any `git` command) unless the task explicitly asks for them. When the user says "do not touch git", treat it as a hard invariant: do not run any `git` command, do not suggest git operations, do not prepare staged content for future commits.
- **Git commit enforcement.** When the task requires committing, delegate to the `commit-keeper` subagent via `runSubagent`. The commit-keeper agent follows `commit-safety.instructions.md` for verification, failure recovery, and amend prohibition. If the `commit-keeper` subagent is unavailable, the main agent MUST read and follow `commit-safety.instructions.md` directly, acting as commit-keeper.
- **Defer privileged operations.** If a task requires `sudo`, admin elevation, or any operation that cannot run as the current user, do not execute it. Instead, note the required privilege in the completion summary and prompt the user to run it.
- See `.agents/instructions/execution-details.instructions.md` for multi-edit fallback and tool-retry discipline.
- **Strict scope adherence.** When the user says "only do X", "only fix X", or otherwise scopes the task to a specific pass, phase, file, or rule, do exactly that scope and nothing else. Do not fix related issues, do not improve surrounding code, do not pre-emptively address future passes, or re-organize or refactor outside the stated scope. The user will explicitly ask for follow-up work if needed.
- **Enumerate subagent opportunities before starting.** Before executing any task, explicitly list which subproblems could be delegated to subagents. Write this list into session memory (`/memories/session/`) if the task is complex. Do not skip this step.
- **Record animated CLIs/TUIs with asciinema.** For detailed usage, invoke the skill: `skill: "asciinema"`.

## Subagent delegation

**MUST use subagents for every delegatable subproblem** — planning, implementation, research, and Q&A with separable concerns. Each subagent gets a dedicated context window, preventing overflow and reducing risk of forgetting earlier details.

**MUST delegate exploration to subagents** — use `Explore` for any multi-file research (≥3 file reads, >1 source file, or broad exploratory questions). Only read files directly for narrow questions (1-2 files).

**MUST prefer subagents for narrow tasks** — 1 subagent turn instead of N+ turns inline. Use `Explore` for research, `General Purpose` for focused implementations.

**Concrete thresholds:**

- ≥3 file reads → `Explore` subagent
- ≥2 independently modifiable files → parallel `General Purpose` subagents
- ≥2 separable questions → one subagent per question
- Steps described as "do X in file Y" → `General Purpose` subagent

**Template:** See `delegate.prompt.md`. Keep prompts short: 2-3 sentence context, one-sentence task, hard constraints, expected return.

## Terminal hygiene

- Discard terminal output after use. After acting on terminal output, summarize the exit code and relevant result in your own words. Do not carry raw terminal output into the next turn's context. Accumulated terminal noise is the single largest input-token waste in multi-turn sessions.
- **Logging vs terminal output.** Use terminal output for command results, build output, and test results. Use issue comments and conversation messages for diagnostics. Do not write progress logs into terminal output that the user will see — prefer structured tool output or in-message summaries.
- **Never filter terminal output with pipes.** Do not pipe terminal output through `grep`, `tail`, `head`, `awk`, `sed`, or any filter — universally, not just for "long-running" commands. The agent cannot reliably distinguish fast from slow commands, so the ban covers all terminal output. Instead, redirect the full output to a temporary file and read that file. If the filter was wrong or the tail was too short, re-grep the saved file — no need to re-run the command. Use `mktemp` or a fixed path under `/tmp/`. Exceptions: reading from a file (grep/tail/head/awk/sed on file paths, not terminal output) is fine; when the user's task is explicitly about text processing ("extract these lines", "find this pattern"), piping is part of the work.

## Research scope

- For queries scoped with "research only", "verify only", or similar boundary markers, produce concise findings (≤~1k chars). Give the key answer and let the user ask for depth. Do not generate comprehensive reports that will be discarded or refined.
- **Default search sources.** When asked to search, consult GitHub, DuckDuckGo, then any other search engines the model is aware of, in that priority order.
- **Strict research-only mode.** When the user says "only verify", "only plan", "only report", "do not edit", or similar scoping phrases, treat this as a hard boundary. Do zero edits, zero file modifications, zero git operations. Report findings only. Do not pre-implement, sketch diffs, or suggest code changes unless explicitly asked.

## Instruction compliance

- **Re-read instructions when context changes.** When a task transitions into a new domain (e.g., switches from editing notes to running Python, or from writing content to debugging a tool), re-read any instruction files that apply to the new context. Do not rely on memory of rules from earlier in the conversation — instruction files are the ground truth.
- **Watch Markdown line wrapping specifically.** When editing `.md` files, `authoring.instructions.md` requires no hard line breaks in paragraphs. Re-read that section before editing — this rule is frequently violated.
- **Critical gotchas (violations cause data loss or task failure):**
  - NEVER `cd` into `.agents/skills/` or any skill subfolder. Always run commands from the repo root. Running inside a skill folder creates `.venv/`/`uv.lock` trash there and fails.
  - NEVER suggest or run `uv run -m init generate` — content generation is automatic. This instruction applies to ALL content in this repo.
  - NEVER suggest or run `uv run -m init generate -C`.
  - ALWAYS use `resolve_memory_file_uri` to resolve paths under `/memories/`. Passing a literal path like `/memories/session/plan.md` or a manually constructed absolute path to `create_file` will silently write into a workspace-local `memories/` directory if one exists. Only the URI returned by `resolve_memory_file_uri` points to the real session memory store.

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
2. Construct the session memory path: `/memories/session/plan-<datetime>.md`.
3. Call `resolve_memory_file_uri` on that path to get the real filesystem URI.
4. Write the plan using `create_file` with the resolved URI. NEVER pass a literal `/memories/` path or a manually constructed absolute path to `create_file`.
5. Verify the file was created in the correct place:
   - Read it with `read_file`.
   - Confirm the resolved path is NOT under any workspace/repo root directory (e.g. no `/Users/.../<reponame>/memories/`).
   - If it is, delete the bad file and redo from step 1.

### Finding the active plan file

Plan files are named `plan-<datetime>.md` in session memory — never `active-plan.md`. Use the find-latest-plan pattern (glob `plan-*.md`, sort by name descending, take the first).

When the user says "refer back to the plan", "verify the plan", "check the plan", or any equivalent phrase:

1. Call `resolve_memory_file_uri("/memories/session/")` to get the base session memory path.
2. Run `ls -1 <base-path>/plan-*.md 2>/dev/null | sort -r | head -1` in a terminal to find the latest file.
3. If no files match, report that no active plan is found. Do not reconstruct or guess — stop.
4. Otherwise, read the file at the returned path.
5. Check the frontmatter: `status: completed` means the plan was fully executed; `status: in-progress` means execution was interrupted. The `current-step` field shows which workflow step was last reached. The `committed` field tracks atomic commit progress: `no` (no commits made), `partial` (some commits made), `yes` (all commits done).
6. Present the plan and its frontmatter status to the user or act as instructed.
