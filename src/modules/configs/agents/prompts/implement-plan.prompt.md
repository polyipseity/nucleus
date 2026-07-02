---
name: implement-plan
description: Execute an implementation plan with subagent parallelism and atomic commits.
argument-hint: "backwardsCompat=no atomicCommits=yes maxConcurrency=1"
---

# Implement plan

Proceed automatically with best-effort defaults. Do not ask for confirmation.

## Workflow

1. **Create the plan file**
   - Generate a temporary file path: use `mktemp` (Linux/macOS) or `$env:TEMP` joined with a random name (Windows). Save the plan there.
   - Write the full implementation plan into that file.
   - Note: the plan file location must be remembered so you can recall it after context compaction.

2. **Implement the plan**
   - Follow the plan from the file, executing each step in order.
   - Simplify code as you edit whenever possible.
   - Backwards compatibility: if `${input:backwardsCompat}` is `yes`, preserve backwards compatibility; otherwise (default), do not add compat shims.
   - Think and work step by step, explain your reasoning. No filler.
   - If `${input:atomicCommits}` is `no`, skip all git operations. Otherwise (default `yes`), commit each atomic change with a precise message after each meaningful sub-step.
   - Re-read the original plan file regularly — especially after interruptions or context switches — to ensure no phase is skipped or misinterpreted.

3. **Use subagents for parallelism**
   - Spawn subagents to manage context and work in parallel on independent lanes.
   - Limit concurrent subagents to `${input:maxConcurrency}` (default 1).
   - Subagents must also follow the step-by-step reasoning and no-filler style.

4. **Verify completeness before finalizing**
   - Re-read the original plan file. Verify every phase is fully implemented.
   - If any phase was ambiguous, re-read the source context that generated the plan.
   - Do not declare completion for phases that were skipped or only partially done.

5. **Finalize**
   - After the plan is fully verified and executed, output a concise summary.
   - Include what was implemented, what files changed, and any deferred items.

## Inputs

- `${input:backwardsCompat}` — `yes` to preserve backwards compatibility; default `no` (do not add compat shims)
- `${input:atomicCommits}` — `no` to skip git commits entirely; default `yes` (commit atomically)
- `${input:maxConcurrency}` — maximum number of concurrent subagents (default 1)
