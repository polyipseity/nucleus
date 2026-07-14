---
name: implement-plan
description: Execute an implementation plan with subagent parallelism and atomic commits.
argument-hint: "backwardsCompat=no atomicCommits=no maxConcurrency=1"
---

# Implement plan

Proceed automatically with best-effort defaults. Do not ask for confirmation.

## Guard clause

If the user's message that triggered this prompt contains "only plan", "only research", "do not start implement", "do not edit files", or any equivalent boundary marker, this prompt MUST NOT auto-execute. Instead, output a brief confirmation of the boundary and stop. Do not create plan files, run commands, or edit anything.

## Workflow

1. **Create the plan file**
   - **Write the plan with a lifecycle frontmatter.** The frontmatter tracks progress (`status`, `current-step`) and input variables, all of which survive context compaction. Use this format:

     ```
     status: in-progress
     current-step: 1
     inputs:
       atomicCommits: ${input:atomicCommits}
       backwardsCompat: ${input:backwardsCompat}
       maxConcurrency: ${input:maxConcurrency}

     # Plan

     <plan content>
     ```
   - **Primary approach — store directly in session memory.** This is the only mechanism that survives context compaction:
     1. Call `resolve_memory_file_uri("/memories/session/active-plan.md")` to get the resolved path.
     2. Write the plan (with metadata header) into that file using `create_file`.
     3. Verify with `read_file` — confirm the content is nonempty and substantive.
     4. From this point forward, always retrieve the plan via `resolve_memory_file_uri("/memories/session/active-plan.md")` + `read_file`. Do not rely on ephemeral variables.
   - **Fallback — if session memory is unavailable** (the tool errors or `create_file` fails):
     1. Generate a temporary file path: use `mktemp` (Linux/macOS) or `$env:TEMP` joined with a random name (Windows). Write the plan there.
     2. Verify with `[[ -s "$planfile" ]]` (POSIX) or `(Get-Item "$planfile").Length -gt 0` (PowerShell).
     3. **Still try to persist the temp file path to session memory** — call `resolve_memory_file_uri("/memories/session/active-plan.md")` and write just `planfile=/path/to/temp/file` there. This gives partial survivability across compaction.
   - **Verify the plan is nonempty and substantive.** Also confirm the content is not just whitespace, a placeholder like "TODO", or a title with no body — use `head -c 200 "$planfile"` (or equivalent) to self-audit. If the file is empty or insubstantial, re-generate the plan and re-verify. Do not proceed to step 2 with a degenerate plan.

2. **Implement the plan**
   - Follow the plan from the file, executing each step in order.
   - Simplify code as you edit whenever possible.
   - Backwards compatibility: if `${input:backwardsCompat}` is `yes`, preserve backwards compatibility; otherwise (default), do not add compat shims.
   - Think and work step by step, explain your reasoning. No filler.
   - If `${input:atomicCommits}` is `yes`, commit each atomic change with a precise message after each meaningful sub-step. Otherwise (default `no`), skip all git operations.
   - Re-read the original plan file regularly — especially after interruptions, subagent returns, or context switches — to ensure no phase is skipped or misinterpreted.
   - **Always retrieve the plan via session memory first:** call `resolve_memory_file_uri("/memories/session/active-plan.md")`, read it. Parse the frontmatter to recover input variables (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) and current progress. If session memory is empty or missing, fall back to the temp file path from step 1.
   - **Update frontmatter after every meaningful sub-step.** Before switching context, calling a subagent, or at any natural break point: read the session memory file, bump `current-step` to the current workflow number, and write back using `replace_string_in_file` or `create_file`. This is how progress survives context compaction — do not skip it.

3. **Use subagents for every opportunity**
   - Spawn subagents for any sufficiently independent subproblem — planning sub-steps, implementing separate files, researching unknowns, or verifying intermediate results. Subagents prevent context overflow and reduce the risk of forgetting earlier requirements by giving each subproblem a fresh, focused context.
   - Limit concurrent subagents to `${input:maxConcurrency}` (default 1). Even at maxConcurrency=1, subagents are highly beneficial — do not skip spawning them just because parallelism is limited.
   - Subagents must also follow the step-by-step reasoning and no-filler style.
   - See `~/.agents/prompts/delegate.prompt.md` for the standardized delegation template.
   - **Before spawning subagents, update frontmatter `current-step` to 3.** Also pass the session memory path in the subagent prompt context so the subagent can read the plan if needed.

4. **Verify completeness before finalizing**
   - Update frontmatter `current-step` to 4.
   - Retrieve the plan: call `resolve_memory_file_uri("/memories/session/active-plan.md")` and read it. If session memory is empty or missing, fall back to the temp file path from step 1. Parse the frontmatter to recover input variables and check current progress.
   - Re-read the original plan file. Verify every phase is fully implemented. Confirm the plan file is nonempty — if it is empty at this point, the plan was lost or corrupted; abort with a clear error rather than guessing the remaining work.
   - If any phase was ambiguous, re-read the source context that generated the plan.
   - Do not declare completion for phases that were skipped or only partially done.

5. **Finalize**
   - After the plan is fully verified and executed, output a concise summary.
   - Include what was implemented, what files changed, and any deferred items.
   - **Update the frontmatter to mark completion** — do NOT delete the plan file. Read the session memory file, set `status: completed` and `current-step: 5`, then write it back. This preserves the plan for later "verify the plan" or "refer back to the plan" requests.

## Inputs

- `${input:backwardsCompat}` — `yes` to preserve backwards compatibility; default `no` (do not add compat shims)
- `${input:atomicCommits}` — `yes` to commit atomically; default `no` (skip git commits entirely)
- `${input:maxConcurrency}` — maximum number of concurrent subagents (default 1)
