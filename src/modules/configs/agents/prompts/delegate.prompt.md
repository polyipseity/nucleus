---
name: delegate
description: "Standardized subagent delegation workflow for any task."
---

# Delegate to a subagent

Use this prompt template whenever you need to delegate a subproblem to a `runSubagent` call.

## When to delegate

Refer to the triggering thresholds in `core-behavior.instructions.md`:

- Research requiring **≥3 file reads** → delegate to `Explore` subagent.
- Task modifying **≥2 independently modifiable files** → consider parallel `General Purpose` subagents (one per file or file group).
- User asks **≥2 separable questions** → delegate each to its own subagent.
- **Any research query involving >1 source file** → `Explore` subagent is the default path.
- A sub-step can be described as "do X in file Y" → delegate it to a `General Purpose` subagent.

## Template

When delegating to subagents, include the active input defaults (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) in the Context section so the subagent is aware of the governing constraints.

```text
runSubagent(
  prompt: "
    Context: <what led to this subproblem, key files, state so far>
    Task: <exact one-sentence task>
    Constraints: <hard boundaries — no git, no deletion, preserve behavior, etc.>
    Return: <what to report back — summary, diffs, findings>
  ",
  description: "<3-5 word summary>",
  agentName: "<General Purpose | Explore>"
)
```

## Review

After the subagent returns, verify its output against the task description. If the output is incomplete or unclear, re-delegate with a narrower scope or more context.
