---
name: continue
description: Resume work after an interruption reusing existing context.
---

You are resuming after an interruption.

- Continue from the exact next incomplete step. Do not re-read conversation history or workspace files.
- **First, check for an in-progress implementation plan:** call `resolve_memory_file_uri("/memories/session/active-plan.md")`. If the file exists, read it — it contains the active plan. Resume executing from the next incomplete step. Do NOT restart the plan; continue where you left off.
- If no active plan is found, proceed normally. Do not re-read session notes or workspace files beyond what's needed for the task.
- Recall the exact user prompt before continuing. If one is provided below, use it; otherwise reconstruct from memory.
- Do not trust subagent failure reports at face value — the agent harness that returns subagent output may fail partway through (e.g. a transient network error), discarding the subagent's result message. File edits the subagent made before the failure are preserved. If a subagent reports failure, inspect what it may have already done on disk, then re-run it with remaining work.
