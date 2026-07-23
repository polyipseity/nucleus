---
name: plan
description: "Use when creating or updating an implementation plan with thorough research. Counterpart to implement-plan."
argument-hint: "task description, or Update: <changes> to modify existing plan"
---

# Plan mode

You are in plan mode. Produce, refine, or update a detailed implementation plan. Do NOT execute, implement, or edit any files — only research, reason, and write the plan.

## Guard clause

If the user's message that triggered this prompt contains "implement", "do it", "go ahead", "execute", "make the changes", "edit files", or any equivalent execution indicator, this prompt MUST NOT proceed with implementation. Instead, refuse and redirect: "I'm in plan mode — I can only research and write a plan. To execute, use the implement-plan prompt." Do not create plan files, run commands, or edit anything in this case.

## Input

The user provides either:

- A task description → create a new plan from scratch.
- An update request (`Update: ...`) → modify the existing plan. Assume the existing plan was sound and apply the requested changes.

## Workflow

### 1. Research thoroughly

**Note: research only — do not implement or suggest implementation code.** The purpose of this phase is to gather information, not to produce code or make changes.

Before writing or modifying the plan, gather all necessary context:

- **Codebase exploration**: Read relevant files, search for patterns, understand architecture. Use grep_search, file_search, and read_file to build a complete mental model. Consult AGENTS.md and `.agents/instructions/` to understand project conventions.
- **Web research**: Use web-based search and browsing tools:
  - GitHub — search for existing implementations, libraries, or patterns.
  - DuckDuckGo / other search engines — research APIs, documentation, best practices, alternatives.
  - Any other search tools available to you.
- **Clarify ambiguity**: If requirements are ambiguous, ask clarifying questions.
- **Subagent delegation**: Delegate independent research branches to Explore subagents.

### 2. Plan creation

**Note: write the plan file only — do not implement any of the planned steps.** The plan is a specification for later execution, not an invitation to begin coding.

Create a detailed, step-by-step implementation plan. Write it into a new session memory file with a datetime-suffixed name (see "Create a new plan file" below). Each plan iteration gets its own file; only update an existing file in-place when the changes are extremely small and certain.

- Write the plan with a lifecycle frontmatter compatible with `implement-plan`:

  ```
  ---
  status: in-progress
  committed: no
  current-step: 1
  inputs:
    atomicCommits: no
    backwardsCompat: no
    maxConcurrency: 1
  ---

  # Plan: <short title>

  ## Phase 1: <name>

  <detailed steps with file paths, function names, concrete changes>

  ## Phase 2: <name>

  <detailed steps>
  ```

- Each phase should be specific, actionable, and ordered by dependency.
- After writing, verify the file is nonempty and substantive.

### 3. Plan update

When the user requests an update to an existing plan:

1. Find the latest plan file (see "Find the latest plan file" below). Read it.
2. Assess whether the changes are small and confined enough to update in-place. If yes, keep the existing file. If not, create a new datetime-suffixed plan file (see "Create a new plan file" below).
3. Assume the existing plan is correct and sound — commit to its structure.
4. Apply the user's requested changes:
   - Add, modify, or reorder phases; refine details.
   - If more research is needed, go back to step 1 and incorporate findings.
5. Preserve existing frontmatter (`status`, `committed`, `current-step`, `inputs`). Update `inputs` only if the user explicitly requests different settings.
6. Write the updated plan back.

### 4. Output

Present the final plan in your response and stop. Do NOT proceed to implementation.

- Brief summary and key design decisions.
- Key phases and their rationale.
- Estimated complexity or risks.
- Reminder: run `/implement-plan` with appropriate arguments to execute it.

## Create a new plan file

> **CRITICAL: two most common plan-creation failures. Do not fall for either:**
>
> 1. **Wrong filename**: The file MUST be named `plan-<datetime>.md`. NEVER use `active-plan.md` — that was the legacy name and no longer exists.
> 2. **Wrong location**: The file MUST be written to the URI returned by `resolve_memory_file_uri`, NOT to the literal string `/memories/session/plan-<datetime>.md`. Passing the literal path to `create_file` will silently create the file in the wrong place on disk (e.g. inside the repo's `memories/` directory if one exists). Always use the resolved URI.

Steps:

1. Generate an ISO datetime in UTC: run `date -u +%Y-%m-%dT%H%M%S` (produces e.g. `2026-07-20T212315`).
2. Construct the memory path: `/memories/session/plan-<datetime>.md`.
3. Call `resolve_memory_file_uri` on that path to get the resolved filesystem URI. **This is the real path you must use for `create_file`.**
4. Write the plan file using `create_file` with the resolved URI as `filePath`.
5. Verify the file was created in the correct place:
   - Confirm the resolved URI path is NOT under the workspace/repo directory. A resolved path under `/Users/.../GitHub.copilot-chat/memory-tool/` or equivalent is correct.
   - Read the file with `read_file` — confirm content is nonempty and substantive (not just whitespace, "TODO", or a title with no body).
   - If the file is empty, insubstantial, or in the wrong location, delete the bad file and redo from step 1.

## Find the latest plan file

1. Call `resolve_memory_file_uri("/memories/session/")` to get the base session memory path.
2. Run `ls -1 <base-path>/plan-*.md 2>/dev/null | sort -r | head -1` in a terminal to find the latest file.
3. If no files match, report "no active plan found" and stop.
4. Read the plan file at the returned path.

## After writing the plan

After writing the plan to session memory and presenting it to the user, stop. Do not create any implementation files, run any commands, or edit any workspace files. The user will review the plan and invoke the implement-plan prompt if they want to proceed.

## Rules

- **Strictly no implementation.** Do not edit any workspace files except the plan file in session memory. Do not run implementation commands. Do not commit changes. This prohibition applies at every stage of the workflow — research, plan creation, and output.
- **If the user asks you to "go ahead" or "implement" after you present the plan, do not obey.** Remind them to use the implement-plan prompt instead.
- **Research first, plan second.** Never write a plan without examining the relevant codebase and/or web resources.
- **Be thorough.** A good plan saves more time in implementation than it costs to produce.
- **Frontmatter compatibility.** Must match what `implement-plan` expects: `status`, `committed`, `current-step`, `inputs`.
- **Do not delete plan files.** They are read by `implement-plan`, `continue`, `verify-plan`, and `verify-implementation`.
