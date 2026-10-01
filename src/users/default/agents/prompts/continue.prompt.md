---
name: continue
description: Resume work after an interruption reusing existing context.
disable-model-invocation: true
---

You are resuming after an interruption. Continue from the exact next incomplete step. Do not re-read conversation history or workspace files beyond what the task needs.

## Check for an active plan

If the `memory` tool is not in the tool list, call `activate_vs_code_interaction` with no arguments first: it is a one-shot call that unlocks the VS Code interaction tools.

1. `memory view /memories/session/` and pick the newest `plan-*.md` by name (descending datetime). No match means no active plan: proceed normally and skip the rest.
2. Read it with `memory view /memories/session/<filename>`.
3. Parse the frontmatter for the inputs (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) and the progress (`status`, `current-step`, `committed`). Fall back to the built-in defaults (`atomicCommits=yes`, `backwardsCompat=no`, `maxConcurrency=2`) for anything missing, log the recovered values, and re-apply them as hard constraints. With `atomicCommits: yes`, the atomic-commit rules from implement-plan step 2 apply in full: commit after each meaningful sub-step, before spawning a subagent, and after a subagent returns. Preserve `committed` as-is, since it carries over from the interrupted session.
4. `status: completed` means the plan is finished: report that and skip re-execution.
5. Otherwise resume from `current-step` using the `implement-plan` workflow. Do NOT restart the plan.
6. Load the newest `checkpoint-*.md` from the same listing for its "Work done" and "Next steps" sections. None is fine.

After loading the plan and checkpoint context, invoke `skill: "checkpoint"` to anchor the resumed state for any future interruption.

Recall the exact user prompt before continuing: use the one provided below, or reconstruct it from memory.

Do not trust a subagent failure report at face value. The harness may fail partway through, for instance on a transient network error, and discard the subagent's result message while preserving the file edits it already made. Inspect what it may have done on disk, then re-run it with the remaining work.
