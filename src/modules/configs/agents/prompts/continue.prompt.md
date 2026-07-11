---
name: continue
description: Resume work after an interruption reusing existing context.
---

You are resuming after an interruption.

- Continue from the exact next incomplete step. Do not re-read conversation history, session notes, workspace files, or any other context already loaded.
- Recall the exact user prompt before continuing. If one is provided below, use it; otherwise reconstruct from memory.
- Do not trust subagent failure reports at face value — the agent harness that returns subagent output may fail partway through (e.g. a transient network error), discarding the subagent's result message. File edits the subagent made before the failure are preserved. If a subagent reports failure, inspect what it may have already done on disk, then re-run it with remaining work.
