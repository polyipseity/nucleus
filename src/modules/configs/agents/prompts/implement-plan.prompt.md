---
name: implement-plan
description: Execute an implementation plan with subagent parallelism and atomic commits.
argument-hint: "backwardsCompat=no atomicCommits=yes maxConcurrency=2"
---

# Implement plan

Proceed automatically with best-effort defaults. Do not ask for confirmation.

## Guard clause

If the user's message that triggered this prompt contains "only plan", "only research", "do not start implement", "do not edit files", or any equivalent boundary marker, this prompt MUST NOT auto-execute. Instead, output a brief confirmation of the boundary and stop. Do not create plan files, run commands, or edit anything.

## Default inputs

Before proceeding, explicitly acknowledge the input values that will govern this execution. These come from (in priority order): (1) explicit user arguments, (2) plan frontmatter `inputs` section, (3) built-in defaults below.

Built-in defaults (used when plan frontmatter omits a field):
- **`atomicCommits: yes`** — commit each meaningful sub-step atomically.
- **`backwardsCompat: no`** — no compatibility shims.
- **`maxConcurrency: 2`** — at most 2 concurrent subagents.

State "Inputs loaded: atomicCommits=<value>, backwardsCompat=<value>, maxConcurrency=<value>" at the start of your response. This acknowledgment must appear before any implementation begins.

## Workflow

1. **Create the plan file**
   - **Write the plan with a lifecycle frontmatter.** The frontmatter tracks progress (`status`, `current-step`) and input variables, all of which survive context compaction. Use this format:

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

     # Plan

     <plan content>
     ```

   > **`current-step` semantics**: In `implement-plan`, `current-step` tracks the workflow step number (1-5), NOT the plan phase number. Plan phases are tracked separately by re-reading the plan body. This prevents confusion between "which workflow step am I on" and "which plan phase am I implementing."

   - **Primary approach — store directly in session memory.** This is the only mechanism that survives context compaction:
     1. Generate an ISO datetime in UTC: run `date -u +%Y-%m-%dT%H%M%S` (produces e.g. `2026-07-20T212315`).
     2. Construct the path as `/memories/session/plan-<datetime>.md` and resolve it via `resolve_memory_file_uri`.
     3. Write the plan (with metadata header) into that file using `create_file`.
     4. Verify with `read_file` — confirm the content is nonempty and substantive.
     5. From this point forward, always retrieve the plan via the find-latest-plan pattern (see "Find the latest plan file" below). Do not rely on ephemeral variables.
   - **Fallback — if session memory is unavailable** (the tool errors or `create_file` fails):
     1. Generate a temporary file path: use `mktemp` (Linux/macOS) or `$env:TEMP` joined with a random name (Windows). Write the plan there.
     2. Verify with `[[ -s "$planfile" ]]` (POSIX) or `(Get-Item "$planfile").Length -gt 0` (PowerShell).
     3. **Still try to persist the temp file path to session memory** — generate a datetime, construct `/memories/session/plan-<datetime>.md`, resolve it via `resolve_memory_file_uri`, and write just `planfile=/path/to/temp/file` there. This gives partial survivability across compaction.
   - **Verify the plan is nonempty and substantive.** Also confirm the content is not just whitespace, a placeholder like "TODO", or a title with no body — use `head -c 200 "$planfile"` (or equivalent) to self-audit. If the file is empty or insubstantial, re-generate the plan and re-verify. Do not proceed to step 2 with a degenerate plan.

2. **Implement the plan**
   - **Recover plan inputs.** Retrieve the plan (find-latest-plan pattern). Parse the frontmatter `inputs` section. If `inputs.atomicCommits` exists, use it; otherwise fall back to built-in default `yes`. Same for `backwardsCompat` and `maxConcurrency`. Log the recovered values.
   - Follow the plan from the file, executing each step in order.
   - Simplify code as you edit whenever possible.
   - Backwards compatibility: if `${input:backwardsCompat}` is `yes`, preserve backwards compatibility; otherwise (default), do not add compat shims.
   - Think and work step by step, explain your reasoning. No filler.
   - If `${input:atomicCommits}` is `yes`, commit each atomic change with a precise message after each meaningful sub-step. Otherwise, skip all git operations.
   - Re-read the original plan file regularly — especially after interruptions, subagent returns, or context switches — to ensure no phase is skipped or misinterpreted.
   - **Always retrieve the plan via session memory first:** use the find-latest-plan pattern (see "Find the latest plan file" below). Parse the frontmatter to recover input variables (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) and current progress (`status`, `current-step`, `committed`). If no plan is found, fall back to the temp file path from step 1.
   - **Update frontmatter after every meaningful sub-step.** Before switching context, calling a subagent, or at any natural break point: retrieve the plan (find-latest-plan pattern), bump `current-step` to the current workflow number, update `committed`, and write back using `replace_string_in_file` or `create_file`. This is how progress survives context compaction — do not skip it.
     Also invoke the checkpoint skill (`skill: "checkpoint"`) after each meaningful sub-step alongside the frontmatter update. This preserves work-done context across interruptions.
     - `committed` transitions: `no` → `partial` (on first atomic commit made during this plan execution). Stay at `partial` on subsequent commits.
     - **Do not set `committed` to `yes` here** — that happens only in step 5, to distinguish "some commits made" from "all commits done".
     - If `inputs.atomicCommits` is `no`, leave `committed` at `no` — no transition needed.

3. **MUST use subagents for every delegatable subproblem**
   - First, invoke the checkpoint skill (`skill: "checkpoint"`) to save current state before delegation.
   - Before any implementation work, enumerate which subproblems can be delegated (separate files, independent phases, parallel research). Write this list to session memory. Spawn subagents for each — planning sub-steps, implementing separate files, researching unknowns, or verifying intermediate results. Subagents prevent context overflow and reduce the risk of forgetting earlier requirements by giving each subproblem a fresh, focused context.
   - Limit concurrent subagents to `${input:maxConcurrency}` (default 2). Even at maxConcurrency=1, subagents are highly beneficial — do not skip spawning them just because parallelism is limited.
   - Subagents must also follow the step-by-step reasoning and no-filler style.
   - See `~/.agents/prompts/delegate.prompt.md` for the standardized delegation template.
   - **Before spawning subagents, update frontmatter `current-step` to 3.** Also pass the plan path in the subagent prompt context so the subagent can read the plan if needed.

4. **Verify completeness before finalizing**
   - Update frontmatter `current-step` to 4.
   - Retrieve the plan: use the find-latest-plan pattern (see "Find the latest plan file" below). If no plan is found, fall back to the temp file path from step 1. Parse the frontmatter to recover input variables and check current progress.
   - Re-read the original plan file. Verify every phase is fully implemented. Confirm the plan file is nonempty — if it is empty at this point, the plan was lost or corrupted; abort with a clear error rather than guessing the remaining work.
   - If any phase was ambiguous, re-read the source context that generated the plan.
   - Do not declare completion for phases that were skipped or only partially done.

5. **Finalize**
   - After the plan is fully verified and executed, output a concise summary.
   - Include what was implemented, what files changed, and any deferred items.
   - **Update the frontmatter to mark completion** — do NOT delete the plan file. Retrieve the plan (find-latest-plan pattern), set `status: completed` and `current-step: 5`. Also:
     - If `inputs.atomicCommits` is `yes` and `committed` is `partial`, set `committed` to `yes`.
     - If `inputs.atomicCommits` is `yes` and `committed` is still `no`, include a warning in the summary: "atomic commits were requested but none were actually made — verify state manually". Leave `committed` at `no`.
   - Write the updated frontmatter back. The plan file remains accessible for later "verify the plan" or "refer back to the plan" requests.

## Find the latest plan file

1. Call `resolve_memory_file_uri("/memories/session/")` to get the base session memory path.
2. Run `ls -1 <base-path>/plan-*.md 2>/dev/null | sort -r | head -1` in a terminal to find the latest file.
3. If no files match, report "no active plan found" and stop.
4. Read the plan file at the returned path.

## Inputs

- `${input:backwardsCompat}` — `yes` to preserve backwards compatibility; default `no` (do not add compat shims)
- `${input:atomicCommits}` — `yes` to commit atomically; default `yes`
- `${input:maxConcurrency}` — maximum number of concurrent subagents (default 2)
