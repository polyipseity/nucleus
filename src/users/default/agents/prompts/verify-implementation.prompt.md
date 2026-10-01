---
description: "Verify that the active plan (plan-*.md in session memory) is fully implemented. If gaps exist, produce a remediation plan without implementing."
disable-model-invocation: true
name: "verify-implementation"
argument-hint: "optional: specific phase or file to focus verification on"
---

# Verify plan implementation

Check whether an active plan is fully implemented. Do NOT execute, implement, or edit any files: research, compare, report.

## Guard clause

If the triggering message contains "implement", "do it", "go ahead", "execute", "make the changes", or any equivalent, refuse and redirect: "I'm in verify mode: I can only check and plan. To execute, use the implement-plan prompt."

If the `memory` tool is missing from the tool list, call `activate_vs_code_interaction` with no arguments first: it is a one-shot call that unlocks the VS Code interaction tools.

## 1. Retrieve the plan

1. `memory view /memories/session/` and pick the newest `plan-*.md` by name (descending datetime). None: report "No active plan found, nothing to verify." and stop.
2. Read it with `memory view /memories/session/<filename>`.
3. Parse the frontmatter (`status`, `current-step`, `committed`, `inputs`) for context. Never short-circuit on `status: completed`: verify regardless.
4. Load the newest `checkpoint-*.md` from the same listing for supplementary context (work done, files touched, pending decisions). None is fine.

## 2. Verify completeness

Collect the full list of expected outcomes from every phase and step, then check each against the workspace: read modified files for the intended change, confirm new files exist at the expected path, confirm removed files are gone, and search for behavioral outcomes by their patterns, imports, or references.

Delegate separate phases or large file sets to `Explore` subagents so the main context stays focused. Log every step as passed or failed with its evidence.

With `inputs.atomicCommits: yes`, compare `git log --oneline` against the plan phases and flag any phase with no matching commit: "Phase N has no commit: changes may be uncommitted or lost."

## 3. Report or remediate

No gaps: report "Plan fully implemented, no gaps found.", optionally with a summary of the phases and key files.

With gaps: name each incomplete step with expected versus actual evidence, and do NOT implement fixes. Instead write a remediation sub-plan. Find the latest plan file, or create a new datetime-suffixed one when none exists; read it; set `status` back to `in-progress` if it was `completed`; set `current-step` to the first failed step; add the gaps as ordered steps with exact file paths, their dependencies, and `current-step` set to the first gap's phase number; write it back. Updating the original plan keeps it the single source of truth.

Then stop, present the findings and the remediation plan, and remind the user to run `/implement-plan`.

## Output format

```
## Verification result: OK

Plan "<title>" is fully implemented.

### What was done
- Phase 1: <summary>: verified
- Phase 2: <summary>: verified
```

```
## Verification result: GAPS FOUND

### Missing or incomplete
- Phase 1, step 2: `<description>`: expected `<X>`, found `<Y>`
- Phase 2, step 1: `<description>`: file `<path>` does not exist

### Remediation plan
Updated plan file with remediation steps. Run `/implement-plan` to execute.
```

## Rules

- No implementation: edit no workspace file except the plan in session memory, run no implementation command, commit nothing.
- Research thoroughly with files, searches, and subagents. Never guess whether something was implemented.
- Cite exact paths, line numbers, and expected versus actual content.
- When unsure, flag it as a gap. Over-reporting beats missing an incomplete step.
