---
name: delegate
description: "Standardized subagent delegation workflow for any task."
disable-model-invocation: true
---

# Delegate to a subagent

Template for delegating a subproblem through a `runSubagent` call. The thresholds live in `core-behavior.instructions.md`: research over 3 file reads or more than 1 source file goes to `Explore`; a task touching 2 or more independently modifiable files goes to parallel `General Purpose` subagents; 2 or more separable questions get one subagent each; a step phrased as "do X in file Y" goes to `General Purpose`.

Include the active input defaults (`atomicCommits`, `backwardsCompat`, `maxConcurrency`) in the Context section so the subagent knows the governing constraints.

```text
runSubagent(
  prompt: "
    Context: <what led to this subproblem, key files, state so far>
    Task: <exact one-sentence task>
    Constraints: <hard boundaries: no git, no deletion, preserve behavior, etc.>
    Return: <what to report back: summary, diffs, findings>
  ",
  description: "<3-5 word summary>",
  agentName: "<General Purpose | Explore>"
)
```

Review the result against the task description. Re-delegate with a narrower scope or more context when the output is incomplete or unclear.
