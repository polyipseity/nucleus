---
name: checkpoint
version: 1.0.0
description: |
  Save session state for context compaction survival and re-anchor the standing orders after a resume. Called automatically during plan and implement-plan workflows at natural break points, after each phase, before subagent calls, and at context pressure.
---

# Checkpoint: save session state

## When to checkpoint

- After completing each phase of an implementation plan
- Before spawning subagents (saves state before delegation)
- After receiving subagent results
- When context is nearing capacity (long conversation, many tool calls)
- Before any multi-edit batch

## What to save

Write a checkpoint file to session memory as `checkpoint-<datetime>.md`. The directory and the operation names come from the session-memory capability, which `~/.agents/instructions/harness-adapters.reference.md` maps for the running harness.

Each checkpoint captures:
- **Standing orders:** the boundary in force, quoted from `~/.agents/instructions/standing-orders.instructions.md`, or `none` when no boundary is active
- **Step context:** current plan step/phase, plan file path, frontmatter state
- **Work done:** 2-3 sentence summary of what was accomplished this session
- **Next steps:** what remains (list items from plan)
- **Cross-file state:** file paths being edited, pending decisions, key search results

## How to save

1. Run `date -u +%Y-%m-%dT%H%M%S` for ISO timestamp.
2. Create the file through the session-memory capability, named `checkpoint-<datetime>.md`, with the checkpoint content.
3. Read it back to confirm it has content.

If the harness exposes no session-memory capability, report that and stop instead of writing the checkpoint as an ordinary project file.

## How to restore

The `continue.prompt.md`, `verify-plan.prompt.md`, and `verify-implementation.prompt.md` workflows each find and load the latest checkpoint when resuming after interruption or context compaction. A checkpoint provides enough context to continue without replaying full history.

On restore, read `~/.agents/instructions/standing-orders.instructions.md` before the first action and restate the checkpoint's boundary line. A checkpoint that records `none` does not lift a boundary the owner set in the current session.

## Integration

The `plan.prompt.md` and `implement-plan.prompt.md` prompts invoke this skill at natural break points. When those prompts invoke `skill: "checkpoint"`, follow the save workflow above. Do not ask for confirmation.
