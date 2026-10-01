---
description: "Use always: agent's invariant operating model covering communication, execution patterns, terminal hygiene, research scope, premise integrity, investigation protocol, and plan completeness."
name: "Core Agent Behavior"
applyTo: "**"
alwaysApply: true
---

Default operating mode for all agent interactions.

## Communication

- Respond in English unless the user asks for another language.
- Keep responses short, direct, and actionable. No motivational padding, repeated plans, or restatements.

## Execution

- Break non-trivial work into ordered steps and finish them end to end.
- Parallelize independent reads, searches, and validations.
- After each burst, report progress and the next action.
- Verify before finishing: run the syntax, lint, test, or runtime checks relevant to the task. Use `get_errors` after each editing round when VS Code interaction is available.
- Read the project architecture docs (`AGENTS.md`, `.agents/instructions/`) before placing new code.
- **Immutable by default.** Every variable, field, return type, and collection reaches for the immutable variant first: `const` over `let`, `readonly` properties, `readonly T[]`, frozen records, read-only borrows. Mutability needs a stated reason. See `programming-principles.instructions.md` and `typing-conventions.instructions.md`.
- **No fallbacks.** When a primary path fails or a dependency is missing, report the failure. Never add a fallback branch or mask a missing value with a default (`or ""`, `?? ""`, `|| ""`, `dict.get(k, "")`, `unwrap_or("")`, a swallowing `except`, `-ErrorAction SilentlyContinue` without a stated reason, `2>$null` without an annotation). Fix the primary path instead.
- **Git boundary.** Run no git command unless the task asks for it. When the user says "do not touch git", do not run git, suggest git, or stage anything.
- **Commit delegation.** When the task requires committing, delegate to the `commit-keeper` subagent. If it is unavailable, act as commit-keeper yourself and follow `commit-safety.instructions.md`.
- **Subagent git boundary.** No subagent runs `git commit` or `git push` except commit-keeper during the commit step. Concurrent git operations from several agents race the prek hooks.
- **Submodule boundary.** Never touch files inside a git submodule unless the user explicitly asks to work in that submodule. Reading through absolute paths from the parent repo root is fine; changes there need an explicit request.
- **Defer privileged operations.** Do not run anything needing `sudo` or admin elevation. Name the required privilege in the completion summary and let the user run it.
- **Strict scope adherence.** When the user scopes a task to one pass, phase, file, or rule, do exactly that. Do not fix adjacent issues or pre-empt later passes.
- Enumerate which subproblems could be delegated before starting, and record the list in session memory for complex tasks.
- Record animated CLIs and TUIs with asciinema: invoke the `asciinema` skill.

## Never silently skip warnings or errors

Every warning and error gets accounted for. Calling one "benign" without proof hides a real problem.

- List each item with its exact output line and source (file or step).
- Give each one exactly one disposition: `fix`, `upstream` (name the project and the issue), `by-design` (cite the flag or code), or `consequence` (fix the root, not the symptom).
- "Benign" needs evidence: the service is confirmed running, the flag is intentional, the upstream bug is named, or the condition is documented.
- An item absent from the plan is an item not investigated. Excluded items still show their disposition.

## Subagent delegation

Use a subagent for every delegatable subproblem; each gets its own context window.

- `Explore` for research over 3 or more file reads or any broad exploratory question. Read files directly only for narrow 1-2 file questions.
- `General Purpose` for focused implementations and for tasks phrased as "do X in file Y".
- 2 or more independently modifiable files means parallel subagents; 2 or more separable questions means one subagent each. Max 2 concurrent.

Prompt shape is in `delegate.prompt.md`: 2-3 sentences of context, one-sentence task, hard constraints, expected return.

## Terminal output pipes

Never pipe terminal output through `grep`, `tail`, `head`, `awk`, `sed`, or any other filter, on any command, however long-running. An agent cannot tell a fast command from a slow one, and a wrong filter means paying for the command twice.

Redirect to a file, then read or filter the file:

```sh
tmpfile=$(mktemp)
some-command > "$tmpfile"
grep foo "$tmpfile" | tail -5
```

Two exceptions: filtering a file that was already written to disk, and when the task is text processing itself.

## Terminal hygiene

- Summarize results in your own words after acting on output. Do not carry raw terminal output into the next turn.
- Terminal output carries command results, build output, and test results. Diagnostics belong in issue comments or conversation messages.

## Research scope

- Scoped queries ("research only", "verify only") get a short answer, under about 1k characters. Give the key result and let the user ask for depth.
- "Only plan", "only research", or "do not edit files" is a hard boundary: zero edits, zero file changes, zero git. Report findings only, without sketching diffs.
- Search GitHub, then DuckDuckGo, then anything else the model knows.

## Filesystem search scope

Run `find`, `rg`, `ls -R`, `tree`, or `git ls-files` only inside the current working directory or the directory the task targets. If a needed file lives outside the project tree, ask where it is instead of searching outward.

## Instruction compliance

- Re-read the instruction files that apply when the task moves into a new domain. They are the ground truth, not earlier conversation.
- Markdown paragraphs are one line each, no hard wrapping (`authoring.instructions.md`).
- Never `cd` into `.agents/skills/` or any skill subfolder. Run from the repo root; a skill folder collects `.venv/` and `uv.lock` trash and fails.
- Never run or suggest `uv run -m init generate` or `uv run -m init generate -C`. Content generation is automatic in this repo.
- Use the `memory` tool for all memory operations. It takes `/memories/...` paths and supports `view`, `create`, `str_replace`, `insert`, `delete`, and `rename`. `memory view /memories/session/` lists session files, so `resolve_memory_file_uri` is only for paths a non-memory tool needs.
- The `memory` tool and other VS Code interaction tools (`get_errors`, `run_vscode_command`, `vscode_askQuestions`) unlock by calling `activate_vs_code_interaction` with no arguments. Do it before concluding a tool is missing. Do not fall back to `resolve_memory_file_uri` plus `read_file`, `create_file`, or `run_in_terminal`: that writes URL-encoded garbage files and bypasses the memory API.

## Premise integrity

Check that the user's key terms, frameworks, and cross-domain mappings are real before answering. When a premise is broken, name the term that fails, say briefly why it does not apply, offer a reframe, and answer that. Never invent metrics, frameworks, or citations to rescue an invalid premise.

## Error handling

- Never downgrade an error to a warning, an info log, or a swallowed failure without explicit approval. Report the failure clearly.
- When the user calls something an error, treat it as an error. Do not reclassify it on your own.

## Plan implementation completeness

Before finishing a multi-phase plan, re-read the plan and verify every phase. Re-read the source when a phase description is ambiguous rather than guessing. Skip nothing unless the plan marks it optional.

Check whether separable subproblems went to subagents. If not, record why delegation would or would not have helped.

Plan files live in session memory as `/memories/session/plan-<datetime>.md`, never `active-plan.md`. Create with `memory create`, `date -u +%Y-%m-%dT%H%M%S` for the name, then read it back to confirm it has content. When the user asks to check the plan, find the newest `plan-*.md`, read its frontmatter (`status: completed`, `in-progress`; `current-step`; `committed: no|partial|yes`), and report or act on it.
