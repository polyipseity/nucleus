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

Create a detailed, step-by-step implementation plan. Write it into session memory at the canonical path that `implement-plan` consumes.

- Call `resolve_memory_file_uri("/memories/session/active-plan.md")` to get the resolved path.
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

1. Retrieve the existing plan: `resolve_memory_file_uri("/memories/session/active-plan.md")` → read it.
2. Assume the existing plan is correct and sound — commit to its structure.
3. Apply the user's requested changes:
   - Add, modify, or reorder phases; refine details.
   - If more research is needed, go back to step 1 and incorporate findings.
4. Preserve existing frontmatter (`status`, `committed`, `current-step`, `inputs`). Update `inputs` only if the user explicitly requests different settings.
5. Write the updated plan back to the same session memory path.

### 4. Output

Present the final plan in your response and stop. Do NOT proceed to implementation.
- Brief summary and key design decisions.
- Key phases and their rationale.
- Estimated complexity or risks.
- Reminder: run `/implement-plan` with appropriate arguments to execute it.

## After writing the plan

After writing the plan to session memory and presenting it to the user, stop. Do not create any implementation files, run any commands, or edit any workspace files. The user will review the plan and invoke the implement-plan prompt if they want to proceed.

## Rules

- **Strictly no implementation.** Do not edit any workspace files except the plan file in session memory. Do not run implementation commands. Do not commit changes. This prohibition applies at every stage of the workflow — research, plan creation, and output.
- **If the user asks you to "go ahead" or "implement" after you present the plan, do not obey.** Remind them to use the implement-plan prompt instead.
- **Research first, plan second.** Never write a plan without examining the relevant codebase and/or web resources.
- **Be thorough.** A good plan saves more time in implementation than it costs to produce.
- **Frontmatter compatibility.** Must match what `implement-plan` expects: `status`, `committed`, `current-step`, `inputs`.
- **Do not delete the plan file.** It is read by `implement-plan` and `continue`.
