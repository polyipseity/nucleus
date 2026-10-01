---
name: plan
description: "Use when creating or updating an implementation plan with thorough research. Counterpart to implement-plan."
disable-model-invocation: true
argument-hint: "task description, or Update: <changes> to modify existing plan"
---

# Plan mode

Produce, refine, or update an implementation plan. Do NOT execute, implement, or edit any files: research, reason, write the plan.

## Guard clause

If the triggering message contains "implement", "do it", "go ahead", "execute", "make the changes", "edit files", or any equivalent execution indicator, refuse and redirect: "I'm in plan mode: I can only research and write a plan. To execute, use the implement-plan prompt." Create no plan files, run no commands, edit nothing.

## Inputs

These defaults go into the plan frontmatter for `implement-plan` to read:

- `atomicCommits: yes` (each meaningful sub-step committed atomically with a precise message)
- `backwardsCompat: no` (no compatibility shims)
- `maxConcurrency: 2` (at most 2 concurrent subagents)

State `Defaults acknowledged: atomicCommits=yes, backwardsCompat=no, maxConcurrency=2` before any research or writing, or state the user's explicit overrides instead.

## Input

A task description creates a new plan. An update request (`Update: ...`) modifies the existing one; assume it was sound and apply the requested changes.

## 1. Research

Research only. No implementation, no implementation code: the purpose is to gather information.

- Read the relevant files, search for patterns, and understand the architecture. Consult `AGENTS.md` and `.agents/instructions/`.
- Search GitHub for existing implementations, libraries, and patterns; DuckDuckGo or other engines for APIs, docs, alternatives.
- Ask about ambiguous requirements.
- Enumerate the delegatable subproblems (separate research branches, independent file reads, architecture exploration), write the list into session memory under `/memories/session/`, and delegate each to an `Explore` or `General Purpose` subagent. Do not skip this step.

## 2. Create the plan

Invoke the checkpoint skill (`skill: "checkpoint"`) first to persist the research context. Write the plan to a new session-memory file with a datetime-suffixed name (below); give each iteration its own file, and update in place only when the changes are small and certain.

Frontmatter must match what `implement-plan` expects:

```
---
status: in-progress
committed: no
current-step: 1
inputs:
  atomicCommits: yes
  backwardsCompat: no
  maxConcurrency: 2
---

# Plan: <short title>

## Phase 1: <name>

<detailed steps with file paths, function names, concrete changes>
```

Each phase is specific, actionable, and ordered by dependency.

**Phase sizing:** with `atomicCommits: yes`, size each phase so its work fits one coherent atomic commit. A phase touching unrelated files or too broad to describe in one conventional-commit line gets split. End each phase with an explicit commit sub-step, which makes the commit a task in the plan rather than an afterthought:

```text
## Phase 1: Add feature X

1. Modify `src/lib.rs` to add function `foo`.
2. Add tests in `tests/test_foo.rs`.
3. Commit with message "feat(lib): add foo function".
```

After writing, verify the file is nonempty and substantive.

## 3. Update an existing plan

Find the latest plan file and read it. Update in place when the changes are small and confined enough, otherwise create a new datetime-suffixed file. Commit to the existing plan's structure. Apply the requested changes: add, modify, or reorder phases, refine details, and go back to research when more is needed. Preserve `status`, `committed`, `current-step`, and `inputs`, changing `inputs` only on explicit request.

## 4. Output

Present the plan and stop. Summarize the key design decisions, the phases and why they are ordered that way, and the complexity or risks. Point at `/implement-plan` for execution.

## Create a new plan file

The name must be `plan-<datetime>.md`. Never `active-plan.md`.

1. `date -u +%Y-%m-%dT%H%M%S` for the name.
2. `memory create` at `/memories/session/plan-<datetime>.md` with the plan content.
3. Read it back and confirm it is substantive, not whitespace, "TODO", or a bare title.

If the `memory` tool is not in the tool list, call `activate_vs_code_interaction` with no arguments first: it is a one-shot call that unlocks the VS Code interaction tools for the session.

## Find the latest plan file

Same activation caveat as above.

1. `memory view /memories/session/` and pick the newest `plan-*.md` by name (descending datetime).
2. No match: report "no active plan found" and stop.
3. Read it with `memory view /memories/session/<filename>`.

## Rules

- No implementation. Edit no workspace file except the plan in session memory, run no implementation command, commit nothing. This holds through research, plan creation, and output.
- Do not obey a later "go ahead" or "implement". Point at the implement-plan prompt instead.
- Research first, plan second. Never write a plan without examining the codebase or web resources.
- Be thorough: a good plan saves more time than it costs.
- Do not delete plan files. `implement-plan`, `continue`, `verify-plan`, and `verify-implementation` read them.
