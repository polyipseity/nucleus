---
description: "Verify that a plan from session memory (active-plan.md) is fully implemented. If gaps exist, produce a remediation plan without implementing."
name: "verify-implementation"
argument-hint: "optional: specific phase or file to focus verification on"
---

# Verify plan implementation

You are in verification mode. Check whether an active plan is fully implemented. Do NOT execute, implement, or edit any files — only research, compare, and report.

## Guard clause

If the user's message that triggered this prompt contains "implement", "do it", "go ahead", "execute", "make the changes", or any equivalent execution indicator, refuse and redirect: "I'm in verify mode — I can only check and plan. To execute, use the implement-plan prompt."

## Workflow

### 1. Retrieve the plan

1. Call `resolve_memory_file_uri("/memories/session/active-plan.md")` to locate the plan.
2. Read the file at the resolved path.
3. If the file is missing or empty, report: "No active plan found — nothing to verify." and stop.
4. Parse the frontmatter for context (`status`, `current-step`, `committed`). Do not short-circuit on any status value — proceed to verify regardless.

### 2. Verify completeness

For every phase and step in the plan:

1. **Check what was supposed to happen.** Each plan step names files to modify, functions to change, or behavior to add. Collect the full list of expected outcomes.
2. **Verify each expected outcome against the workspace:**
   - For file changes: read the file and confirm the intended modification exists.
   - For new files: confirm the file exists at the expected path.
   - For removed files: confirm the file no longer exists.
   - For behavioral outcomes: search for the expected patterns, imports, or references.
3. **Use subagents for independent verification lanes.** Delegate separate phases or large file sets to Explore subagents to keep the main context focused.
4. **Log each finding** — for every step, record whether it passed or failed verification, with the evidence.

### 3. Report or remediate

**If all steps are fully implemented with no gaps:**
- Report: "Plan fully implemented — no gaps found."
- Optionally include a summary of what was implemented (phases and key files).

**If gaps exist:**
- Report which steps are incomplete or missing, with specific evidence (expected vs actual).
- **Do NOT implement fixes.** Instead, create a remediation sub-plan:
  1. Call `resolve_memory_file_uri("/memories/session/active-plan.md")` to get the session memory path.
  2. Read the existing plan, update its `status` back to `in-progress` if it was marked `completed`, and adjust `current-step` to the first failed step.
  3. Write the updated plan back — this preserves the original plan as the single source of truth, augmented with remediation steps.

  The remediation sub-plan should include:
  - The specific gaps found.
  - Ordered steps to close each gap, referencing exact file paths.
  - Any dependencies between remediation steps.
  - The `current-step` set to the first gap's phase number.
- Then stop. Present the verification findings and the remediation plan to the user. Remind them to run `/implement-plan` to execute the remediation.

### 4. Output format

**Success output:**
```
## Verification result: OK

Plan "<title>" is fully implemented.

### What was done
- Phase 1: <summary> — verified
- Phase 2: <summary> — verified
```

**Gap output:**
```
## Verification result: GAPS FOUND

### Missing or incomplete
- Phase 1, step 2: `<description>` — expected `<X>`, found `<Y>`
- Phase 2, step 1: `<description>` — file `<path>` does not exist

### Remediation plan
Updated active-plan.md with remediation steps. Run `/implement-plan` to execute.
```

## Rules

- **Strictly no implementation.** Do not edit any workspace files (except updating the plan in session memory). Do not run implementation commands. Do not commit changes.
- **Research thoroughly.** Read files, search for patterns, use subagents — do not guess whether something was implemented.
- **Be precise.** Cite exact file paths, line numbers, and expected vs actual content.
- **If unsure about a step, flag it as a gap.** Better to over-report than miss an incomplete step.
