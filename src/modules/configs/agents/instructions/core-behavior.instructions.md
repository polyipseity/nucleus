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
- **No fallbacks.** Never add fallback paths in code. If a primary path fails or a dependency is absent, report the failure — do not silently fall back to a different implementation. Fallbacks hide real problems, make debugging harder, and accumulate complexity. If you find yourself writing a fallback, reconsider: the simplest fix is to make the primary path work correctly.
- **Git boundary.** Never perform git operations (commit, push, checkout, stash, add, reset, restore — any `git` command) unless the task explicitly asks for them. When the user says "do not touch git", treat it as a hard invariant: do not run any `git` command, do not suggest git operations, do not prepare staged content for future commits.
- **Defer privileged operations.** If a task requires `sudo`, admin elevation, or any operation that cannot run as the current user, do not execute it. Instead, note the required privilege in the completion summary and prompt the user to run it.
- See `.agents/instructions/execution-details.instructions.md` for multi-edit fallback and tool-retry discipline.
- **Strict scope adherence. When the user says "only do X", "only fix X", or otherwise scopes the task to a specific pass, phase, file, or rule, do exactly that scope and nothing else. Do not fix related issues, do not improve surrounding code, do not pre-emptively address future passes, or re-organize or refactor outside the stated scope. The user will explicitly ask for follow-up work if needed.
- **Enumerate subagent opportunities before starting.** Before executing any task, explicitly list which subproblems could be delegated to subagents. Write this list into session memory (`/memories/session/`) if the task is complex. Do not skip this step.
- **Capture animated CLIs/TUIs with asciinema/PowerSession for LLM context.** When a task involves demonstrating, debugging, or documenting an animated CLI or TUI, record the terminal session using `asciinema rec <file>.cast` (POSIX) or `PowerSession.exe rec <file>.cast` (Windows). Convert to plain text with `asciinema convert <file>.cast <file>.txt` (POSIX) or `PowerSession.exe convert <file>.cast <file>.txt` (Windows) — this strips ANSI codes and resolves screen overwrites via the embedded `avt` virtual terminal library. Include the resulting `.txt` file in context when the task requires analysis or documentation of the recorded behavior.

## Git commit safety

### Verify every commit attempt

After EVERY `git commit` command (whether it succeeds or fails):

1. Run `git rev-parse HEAD` and `git log -1 --format=%s`.
2. Confirm the hash is new (different from before the attempt) and the message
   matches your intended message.
3. If the hash/message match the PREVIOUS commit (not the one you tried to
   create), the commit was NOT created. HEAD did not move.

### Recovery from a failed commit

When a commit fails (pre-commit hook, commitlint, etc.), the commit was NOT
created. HEAD is still at whatever it was before the attempt.

Recovery steps:
1. **Read the hook output.** Identify the root cause.
2. **If an auto-formatting hook modified files**, re-stage them:
   `git add <files>`.
3. **If a lint/validation hook rejected the message**, fix the underlying issue.
   For commitlint: correct the message format (add type prefix, wrap lines at
   72 chars).
4. **Retry with a FRESH `git commit`. NEVER use `git commit --amend`.**

### AMEND PROHIBITION — hard rule

`git commit --amend` is FORBIDDEN after a failed commit. It is also FORBIDDEN
without positive verification that HEAD points to the commit you just created.

Why: a failed commit means HEAD did not move. `git commit --amend` modifies
whatever HEAD currently points to — which is a pre-existing commit, not the
one you tried to create. This destroys history by altering an existing commit.

The ONLY safe use of `git commit --amend`:
1. You just ran `git commit` and it SUCCEEDED (exit code 0).
2. You verified with `git rev-parse HEAD` that the hash is new.
3. You need to amend the message of that NEW commit.
4. You run `git commit --amend` to modify only that new commit.

After a commit failure: always retry with a fresh `git commit`. Never amend.

### Concrete failure modes

**Commitlint rejection:** The message format was rejected. The commit was not
created. HEAD is still at the previous commit. Fix the message and retry:
`git commit -m "type(scope): correct message"`. Do NOT use `--amend`.

**Auto-formatting hook (nixfmt, prettier):** The hook modified staged files.
The commit was not created (hooks run before commit finalization). Re-stage:
`git add <files>`, then retry with a fresh `git commit`.

**Blind retries waste time.** Hook failures always indicate a problem in
staged content or a tool that modified it. Diagnose before re-attempting.

## Subagent delegation

**You MUST use subagents for every delegatable subproblem.** Delegate planning, implementation, research, and question-answering to `runSubagent` whenever a task has distinct subproblems. The default max concurrency for subagents is 1, but that does not diminish the benefit: each subagent gets a dedicated context window, preventing context overflow and reducing the risk of forgetting earlier details. Subagent use is mandatory for any task with separable concerns. This is a hard rule, not a suggestion.

**You MUST delegate exploration to subagents.** When the user asks a broad exploratory question or says "research only", use `runSubagent` with agentName `"Explore"` as the default approach. The subagent does the file reading and reasoning in its own context; you get a compact summary. Only read files directly when the question is narrow (one or two files). This is a hard rule, not a suggestion.

**You MUST prefer subagents for narrow tasks.** Use `Explore` for research and `General Purpose` for focused implementations — they cost 1 turn instead of the N turns an inline chat session would consume. This is a hard rule, not a suggestion.

**Concrete triggering thresholds.** Use these to determine when delegation is required:

- Research requiring **≥3 file reads** → delegate to `Explore` subagent.
- Task modifying **≥2 independently modifiable files** → consider parallel `General Purpose` subagents (one per file or file group).
- User asks **≥2 separable questions** → delegate each to its own subagent.
- **Any research query involving >1 source file** → `Explore` subagent is the default path.
- A sub-step can be described as "do X in file Y" → delegate it to a `General Purpose` subagent.

**Subagent prompt templates.** Structure every `runSubagent` call as follows:

```text
runSubagent(
  prompt: "
    Context: <2-3 sentences describing the subproblem, file paths involved, and any invariants.>
    Task: <one sentence describing exactly what to do.>
    Constraints: <any hard constraints — no git, no deletion, must preserve behavior, etc.>
    Return: <what information to return — summary of changes, results, or findings.>
  ",
  description: "<3-5 word summary of the subproblem>",
  agentName: "<General Purpose | Explore>"
)
```

**Good example (Explore):**

```text
runSubagent(
  prompt: "I need to find all callers of function `applyConfig` in the nucleus repo under src/. Search across all .nix and .ps1 files. Return the file paths and line numbers of each call site.",
  description: "Find applyConfig callers",
  agentName: "Explore"
)
```

**Good example (General Purpose):**

```text
runSubagent(
  prompt: "Context: updating the Windows DSC config in src/hosts/Windows/user.dsc.yml. Task: add a WinGet package entry for 'GitHub.cli' with version 'latest'. Constraints: preserve alphabetical sorting of the Packages array. Return: a summary of what was added.",
  description: "Add gh CLI to DSC",
  agentName: "General Purpose"
)
```

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

### Finding the active plan file

When the user says "refer back to the plan", "verify the plan", "check the plan", or any equivalent phrase:

1. Call `resolve_memory_file_uri("/memories/session/active-plan.md")` to locate the plan.
2. Read the file at the resolved path — it contains the plan with a frontmatter header.
3. Check the frontmatter: `status: completed` means the plan was fully executed; `status: in-progress` means execution was interrupted. The `current-step` field shows which workflow step was last reached. The `committed` field tracks atomic commit progress: `no` (no commits made), `partial` (some commits made), `yes` (all commits done).
4. Present the plan and its frontmatter status to the user or act as instructed.

If the session memory file is empty or missing, report that no plan is currently tracked. Do not guess or reconstruct.
