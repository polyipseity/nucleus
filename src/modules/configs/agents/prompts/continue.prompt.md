---
name: continue
description: Resume work from a previous session, ensuring full context recovery and seamless continuation.
---

# Continue

You are resuming work from a previous session.

## Context Recovery

Before proceeding, complete these steps to regain full context:

1. **Review previous work**: Check the conversation history to identify what was completed and what remains.
2. **Load session memory**: Review `/memories/session/` files for in-progress notes, decisions, and blockers.
3. **Verify state**: Confirm current file, test, and deployment status for referenced work.

## Resumption Guidelines

- **Start exactly where you left off**: If a task was marked `in-progress`, resume that specific task—do not start new work.
- **Maintain consistency**: Follow the same approach, coding style, and conventions as the previous session.
- **Validate before proceeding**: If any assumptions from the previous session are unclear, verify them before acting.
- **Update task tracking**: Mark tasks completed immediately after finishing each one; do not batch completions.
- **Preserve atomic structure**: Keep commits, tests, and logical units independent (one feature/fix per commit).

## What to Do Now

1. Review the immediate context above (conversation history, memory, task list).
2. If work is incomplete: Resume the exact next step from the previous session.
3. If work is complete: Ask for the next objective.
4. If blocked: Report the blocker with exact error text, file path, and command output.

## Constraints & Best Practices

- Do not skip validation steps or tests that were established in previous sessions.
- Do not re-implement features that were already completed—reuse validated code.
- Do not create new branches or stash work; work within the current session context.
- Keep responses concise and fact-based; focus on continuation, not re-explanation.
- When user intent is unclear, ask targeted clarifying questions instead of guessing.

End of prompt.
