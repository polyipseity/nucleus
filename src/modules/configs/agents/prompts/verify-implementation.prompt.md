---
description: "Verify that the active plan (plan-*.md in session memory) is fully implemented. If gaps exist, produce a remediation plan without implementing."
name: "verify-implementation"
argument-hint: "optional: specific phase or file to focus verification on"
---

# Verify plan implementation

You are in verification mode. Check whether an active plan is fully implemented. Do NOT execute, implement, or edit any files — only research, compare, and report.

## Guard clause

If the user's message that triggered this prompt contains "implement", "do it", "go ahead", "execute", "make the changes", or any equivalent execution indicator, refuse and redirect: "I'm in verify mode — I can only check and plan. To execute, use the implement-plan prompt."

## Workflow

### 1. Retrieve the plan

1. Find the latest plan file:
   - Call `resolve_memory_file_uri("/memories/session/")` to get the base session memory path.
   - Run `ls -1 <base-path>/plan-*.md 2>/dev/null | sort -r | head -1` in a terminal.
   - If no files match, report: "No active plan found — nothing to verify." and stop.
2. Read the plan file at the returned path.
3. Parse the frontmatter for context (`status`, `current-step`, `committed`). Do not short-circuit on any status value — proceed to verify regardless.
4. Parse `inputs` from frontmatter. Record `atomicCommits`, `backwardsCompat`, `maxConcurrency` for awareness — not used during verification but helpful context for the report.
5. Find and load the latest checkpoint for supplementary context:
   - Run `ls -1 <base-path>/checkpoint-*.md 2>/dev/null | sort -r | head -1` to locate the latest checkpoint.
   - If a checkpoint exists, read it — the checkpoint's "Work done" and "Next steps" sections provide rich verification context (what was just implemented, what files were touched, pending decisions).
   - If no checkpoint exists, proceed without it.

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

5. **When plan `inputs.atomicCommits` is `yes`**, also verify that commits exist matching the plan:
   - Run `git log --oneline` and compare commit messages against plan phases.
   - If a plan phase has no corresponding commit, flag it as a gap: "Phase N has no commit — changes may be uncommitted or lost."

### 3. Report or remediate

**If all steps are fully implemented with no gaps:**

- Report: "Plan fully implemented — no gaps found."
- Optionally include a summary of what was implemented (phases and key files).

**If gaps exist:**

- Report which steps are incomplete or missing, with specific evidence (expected vs actual).
- **Do NOT implement fixes.** Instead, create a remediation sub-plan:
  1. Find the latest plan file (find-latest-plan pattern). If none exists, create a new datetime-suffixed plan file.
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
Updated plan file with remediation steps. Run `/implement-plan` to execute.
```

## Rules

- **Strictly no implementation.** Do not edit any workspace files (except updating the plan in session memory). Do not run implementation commands. Do not commit changes.
- **Research thoroughly.** Read files, search for patterns, use subagents — do not guess whether something was implemented.
- **Be precise.** Cite exact file paths, line numbers, and expected vs actual content.
- **If unsure about a step, flag it as a gap.** Better to over-report than miss an incomplete step.
