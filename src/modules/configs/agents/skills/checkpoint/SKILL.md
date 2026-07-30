---
name: checkpoint
version: 1.0.0
description: |
  Save session state for context compaction survival. Called automatically
  during plan and implement-plan workflows at natural break points — after
  each phase, before subagent calls, and at context pressure.
---

# Checkpoint: save session state

## When to checkpoint

- After completing each phase of an implementation plan
- Before spawning subagents (saves state before delegation)
- After receiving subagent results
- When context is nearing capacity (long conversation, many tool calls)
- Before any multi-edit batch

## What to save

Write a checkpoint file to session memory at `/memories/session/checkpoint-<datetime>.md`.

Each checkpoint captures:
- **Step context:** current plan step/phase, plan file path, frontmatter state
- **Work done:** 2-3 sentence summary of what was accomplished this session
- **Next steps:** what remains (list items from plan)
- **Cross-file state:** file paths being edited, pending decisions, key search results

## How to save

> **Memory tool availability:** If the `memory` tool is not in the available tool list, call `activate_vs_code_interaction` with no arguments first — it is a one-shot call that permanently unlocks VS Code interaction tools.

1. Run `date -u +%Y-%m-%dT%H%M%S` for ISO timestamp.
2. Construct path `/memories/session/checkpoint-<datetime>.md`.
3. Call `memory create` with path `/memories/session/checkpoint-<datetime>.md` and `file_text` containing the checkpoint content.

## How to restore

The `continue.prompt.md`, `verify-plan.prompt.md`, and `verify-implementation.prompt.md` workflows each find and load the latest checkpoint when resuming after interruption or context compaction. A checkpoint provides enough context to continue without replaying full history.

## Integration

The `plan.prompt.md` and `implement-plan.prompt.md` prompts invoke this skill at natural break points. When those prompts invoke `skill: "checkpoint"`, follow the save workflow above. Do not ask for confirmation.
