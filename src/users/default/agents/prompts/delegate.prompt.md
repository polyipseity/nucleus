---
name: delegate
description: "Standardized subagent delegation workflow for any task."
disable-model-invocation: true
argument-hint: "<subproblem>"
---

# Delegate to a subagent

Read `.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `.agents/instructions/harness-adapters.reference.md`.

## Subproblem

$@

Empty means: take the subproblem from the immediately preceding message.

Launch a child through the child-agent capability named in the adapter reference. Paste the `Child prompt block` from `.agents/instructions/standing-orders.instructions.md` verbatim above the context; a child does not inherit that file.

The thresholds live in `core-behavior.instructions.md`: research over 3 file reads or more than 1 source file goes to a research agent; a task touching 2 or more independently modifiable files goes to parallel research agents; 2 or more separable questions get one subagent each; a step phrased as "do X in file Y" goes to an implementation agent. A plan-authoring turn delegates read-only work only.

Include the active input defaults (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) in the Context section so the subagent knows the governing constraints.

```text
child agent(
  prompt: "
    <Child prompt block, pasted verbatim>
    Context: <what led to this subproblem, key files, state so far>
    Task: <exact one-sentence task>
    Constraints: <hard boundaries: no git, no deletion, preserve behavior, etc.>
    Return: <what to report back: summary, diffs, findings>
  ",
  description: "<3-5 word summary>",
  agent: "<research agent | implementation agent>"
)
```

Review the result against the task description. Re-delegate with a narrower scope or more context when the output is incomplete or unclear.
