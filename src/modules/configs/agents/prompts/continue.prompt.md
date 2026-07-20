---
name: continue
description: Resume work after an interruption reusing existing context.
---

You are resuming after an interruption.

- Continue from the exact next incomplete step. Do not re-read conversation history or workspace files.
- **First, check for an in-progress implementation plan:**
  1. Find the latest plan file:
     - Call `resolve_memory_file_uri("/memories/session/")` to get the base session memory path.
     - Run `ls -1 <base-path>/plan-*.md 2>/dev/null | sort -r | head -1` in a terminal to locate the latest plan file.
     - If no files match, no active plan is found — proceed normally (skip steps 2-5).
  2. Read the plan file — it contains the active plan with a lifecycle frontmatter.
  3. Parse the frontmatter to recover input variables (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) and current progress (`status`, `current-step`, `committed`). Re-apply these to the resumed execution (e.g., commit atomically if `atomicCommits: yes`; preserve the `committed` value as-is — it carries over from the interrupted session).
  4. If `status` is `completed`, report that the plan is already finished and skip re-execution.
  5. Otherwise, resume executing from the `current-step` value using the `implement-plan` workflow. Do NOT restart the plan.
- If no active plan is found, proceed normally. Do not re-read session notes or workspace files beyond what's needed for the task.
- Recall the exact user prompt before continuing. If one is provided below, use it; otherwise reconstruct from memory.
- Do not trust subagent failure reports at face value — the agent harness that returns subagent output may fail partway through (e.g. a transient network error), discarding the subagent's result message. File edits the subagent made before the failure are preserved. If a subagent reports failure, inspect what it may have already done on disk, then re-run it with remaining work.
