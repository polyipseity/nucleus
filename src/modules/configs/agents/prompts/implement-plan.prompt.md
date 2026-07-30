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
     2. Use the `memory` tool with command `create`, path `/memories/session/plan-<datetime>.md`, and `file_text` containing the plan content (with frontmatter).
     3. Verify with `memory view /memories/session/plan-<datetime>.md` — confirm the content is nonempty and substantive.
     4. From this point forward, always retrieve the plan via the find-latest-plan pattern (see "Find the latest plan file" below). Do not rely on ephemeral variables.
   - **Fallback — if session memory is unavailable** (the `memory` tool errors or `memory create` fails):
     First, call `activate_vs_code_interaction` with no arguments to unlock VS Code interaction tools. This one-shot call permanently unlocks the `memory` tool and disappears from the tool list after activation. Retry the `memory create` after activation.
     1. Call `activate_vs_code_interaction` with no arguments.
     2. Retry `memory create` — if it succeeds, proceed normally.
     3. **If `activate_vs_code_interaction` is unavailable or `memory create` still fails**, use a temporary file as last resort: use `mktemp` (Linux/macOS) or `$env:TEMP` joined with a random name (Windows). Write the plan there.
     4. Verify with `[[ -s "$planfile" ]]` (POSIX) or `(Get-Item "$planfile").Length -gt 0` (PowerShell).
     5. **Still try to persist the temp file path to session memory** — generate a datetime, then use the `memory` tool with command `create`, path `/memories/session/plan-<datetime>.md`, and `file_text` containing `planfile=/path/to/temp/file`. This gives partial survivability across compaction.
   - **Verify the plan is nonempty and substantive.** Also confirm the content is not just whitespace, a placeholder like "TODO", or a title with no body — use `memory view /memories/session/plan-<datetime>.md` (or `head -c 200 "$planfile"` for fallback) to self-audit. If the file is empty or insubstantial, re-generate the plan and re-verify. Do not proceed to step 2 with a degenerate plan.

2. **Implement the plan**
   - **Recover plan inputs.** Retrieve the plan (find-latest-plan pattern). Parse the frontmatter `inputs` section. If `inputs.atomicCommits` exists, use it; otherwise fall back to built-in default `yes`. Same for `backwardsCompat` and `maxConcurrency`. Log the recovered values.
   - Follow the plan from the file, executing each step in order.
   - Simplify code as you edit whenever possible.
   - Backwards compatibility: if `${input:backwardsCompat}` is `yes`, preserve backwards compatibility; otherwise (default), do not add compat shims.
   - Think and work step by step, explain your reasoning. No filler.

### Atomic commit enforcement

> **⚠️ CRITICAL: When `inputs.atomicCommits` is `yes`, you MUST commit after every meaningful sub-step (defined below). Do not skip — this is actively enforced.**

When `inputs.atomicCommits` (from plan frontmatter) is `yes`:

- **Commit after EVERY meaningful sub-step.** A meaningful sub-step is: adding a function, creating/modifying a file, completing a subagent's returned work, or finishing any unit of work described as a bullet in the plan.
- **Before moving to the next step within a phase**, verify the current change is committed. If not, commit first.
- **Use precise commit messages.** Follow conventional-commit format (`type(scope): subject`). Each commit should describe exactly what changed, not a vague summary.
- **If you are uncertain whether a change is worth a commit, it is — commit it.** Over-committing is far better than under-committing.

When `inputs.atomicCommits` is `no` (or absent, falling back to default `yes` — see Inputs section): skip all git operations. Do not commit.

**Hard rule:** Never batch multiple unrelated changes into a single commit. Each commit must be a coherent, single-purpose change.

   - Re-read the original plan file regularly — especially after interruptions, subagent returns, or context switches — to ensure no phase is skipped or misinterpreted.
   - **Always retrieve the plan via session memory first:** use the find-latest-plan pattern (see "Find the latest plan file" below). Parse the frontmatter to recover input variables (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) and current progress (`status`, `current-step`, `committed`). If no plan is found, fall back to the temp file path from step 1.
   - **Update frontmatter after every meaningful sub-step.** Before switching context, calling a subagent, or at any natural break point: retrieve the plan (find-latest-plan pattern), bump `current-step` to the current workflow number, update `committed`, and write back using the `memory` tool with command `str_replace`. Do not use `memory create` to overwrite an existing plan file — `memory str_replace` preserves the frontmatter and only changes the relevant fields.
     Also invoke the checkpoint skill (`skill: "checkpoint"`) after each meaningful sub-step alongside the frontmatter update. This preserves work-done context across interruptions.
     - `committed` transitions: `no` → `partial` (on first atomic commit made during this plan execution). Stay at `partial` on subsequent commits.
     - **Do not set `committed` to `yes` here** — that happens only in step 5, to distinguish "some commits made" from "all commits done".
     - If `inputs.atomicCommits` is `no`, leave `committed` at `no` — no transition needed.

**Pre-subagent commit gate:** Before spawning any subagent, ensure all work completed so far in the current phase is committed. If uncommitted changes exist, commit them first — do not delegate with a dirty working tree. Update the plan frontmatter `committed` field after committing.

3. **MUST use subagents for every delegatable subproblem**
   - First, invoke the checkpoint skill (`skill: "checkpoint"`) to save current state before delegation.
   - Before any implementation work, enumerate which subproblems can be delegated (separate files, independent phases, parallel research). Write this list to session memory. Spawn subagents for each — planning sub-steps, implementing separate files, researching unknowns, or verifying intermediate results. Subagents prevent context overflow and reduce the risk of forgetting earlier requirements by giving each subproblem a fresh, focused context.
   - Limit concurrent subagents to `${input:maxConcurrency}` (default 2). Even at maxConcurrency=1, subagents are highly beneficial — do not skip spawning them just because parallelism is limited.
   - Subagents must also follow the step-by-step reasoning and no-filler style.
   - See `~/.agents/prompts/delegate.prompt.md` for the standardized delegation template.
   - **Before spawning subagents, update frontmatter `current-step` to 3.** Also pass the plan path in the subagent prompt context so the subagent can read the plan if needed.

**Post-subagent commit requirement:** When each subagent returns:
1. Review the subagent's changes (file modifications, new files, deletions).
2. Commit the changes atomically with a precise message describing what the subagent accomplished.
3. Only then process the next subagent result or advance to the next plan phase.

Do not batch multiple subagent results into one commit — commit each subagent's work separately.

4. **Verify completeness before finalizing**
   - Update frontmatter `current-step` to 4.
   - Retrieve the plan: use the find-latest-plan pattern (see "Find the latest plan file" below). If no plan is found, fall back to the temp file path from step 1. Parse the frontmatter to recover input variables and check current progress.
   - Re-read the original plan file. Verify every phase is fully implemented. Confirm the plan file is nonempty — if it is empty at this point, the plan was lost or corrupted; abort with a clear error rather than guessing the remaining work.
   - If any phase was ambiguous, re-read the source context that generated the plan.
   - Do not declare completion for phases that were skipped or only partially done.

**If `inputs.atomicCommits` is `yes`**, also verify commit history:
- Run `git log --oneline -<number-of-phases>` and confirm each phase has at least one commit.
- If a phase has no commits, flag it as incomplete and re-execute with proper commits before proceeding.

5. **Finalize**
   - After the plan is fully verified and executed, output a concise summary.
   - Include what was implemented, what files changed, and any deferred items.
   - **Update the frontmatter to mark completion** — do NOT delete the plan file. Retrieve the plan (find-latest-plan pattern), set `status: completed` and `current-step: 5`. Also:
     - **If `inputs.atomicCommits` is `yes` and `committed` is `no`:** this is a FAILURE. Do NOT set `status: completed`. Instead:
       1. Log "FAILURE: atomicCommits was requested but no commits were made."
       2. Re-read the plan and re-execute from phase 1 with the commit enforcement rules above.
       3. Update `current-step` to 2 (re-implementing) and keep `status: in-progress`.
     - **If `inputs.atomicCommits` is `yes` and `committed` is `partial`:** set `committed` to `yes`. Normal success path.
     - **If `inputs.atomicCommits` is `no`:** leave `committed` at `no`. Normal success path.
   - Write the updated frontmatter back. The plan file remains accessible for later "verify the plan" or "refer back to the plan" requests.

## Find the latest plan file

1. Use `memory view /memories/session/` to list session files. Find the most recent `plan-*.md` by sorting names (descending datetime).
2. If no files match, report "no active plan found" and stop.
3. Read the plan file using `memory view /memories/session/<filename>`.

## Inputs

- `${input:backwardsCompat}` — `yes` to preserve backwards compatibility; default `no` (do not add compat shims)
- `${input:atomicCommits}` — `yes` to commit atomically; default `yes`
- `${input:maxConcurrency}` — maximum number of concurrent subagents (default 2)
