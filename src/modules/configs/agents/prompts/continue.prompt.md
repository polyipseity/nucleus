---
name: continue
description: Resume work from a previous session, ensuring full context recovery and seamless continuation.
---

# Continue

You are resuming work from a previous session.

## Recovery checklist

Before doing new work:

1. Review conversation history to confirm completed vs. pending work.
2. Load `/memories/session/` notes (if any) for decisions, blockers, and next steps.
3. Verify current workspace state (files, tests, deployment status) for referenced tasks.

## Resume rules

1. Resume the exact next incomplete step; do not start unrelated work.
2. Keep the existing approach, style, and conventions unless explicitly changed.
3. Validate unclear assumptions before coding.
4. Update task tracking as steps complete (no batched status updates).
5. Keep commits/tests/logical changes atomic.

## Decision gates

- If blocked, report exact error text, file path, and command output.
- If previous work is complete, ask for the next objective.

## Constraints

- Do not skip established validation/test steps.
- Do not re-implement completed features; reuse verified work.
- Do not create new branches or stash work.
- Keep responses concise and continuation-focused.
- If intent is unclear, ask targeted clarifying questions.

End of prompt.
