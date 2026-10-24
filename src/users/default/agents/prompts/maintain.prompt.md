---
name: maintain
description: Aggressively improve maintainability via repeated parallel waves of maintainer subagents, with strict atomic commit discipline and rollback safety.
disable-model-invocation: true
argument-hint: "[target glob]"
---

# Maintainability improvement loop

Read `~/.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `~/.agents/instructions/harness-adapters.reference.md`.

Remove unnecessary complexity across code, docs, and AI customizations while preserving behavior.

## Workflow

1. Capture the baseline hash with `git rev-parse HEAD`; never roll back earlier.
2. Resolve the target: `${1:-**/*}`. Lane hints: `${@:2}`.
3. Partition the scope into independent lanes.
4. Run parallel `maintainer` subagents, one per lane:

   ```text
   Improve maintainability across the resolved target.
   Be aggressive: remove unnecessary indirection, duplicated policy,
   stale guidance, and avoidable abstractions.
   Preserve behavior.
   Report: (1) changes made with file paths, (2) simplifications applied,
   (3) remaining hotspots, (4) recommended atomic commit slices.
   ```

5. Merge the lane results and commit in atomic slices.
6. Run another parallel wave on the remaining hotspots.
7. Stop when every lane is down to cosmetic improvements.

## Constraints

- NEVER ask a subagent to run git commit. The MAIN agent commits, so parallel agents cannot race the prek hooks.
- No speculative refactors.
- Preserve behavior and repository conventions.
- Keep commits small, coherent, and reversible.

## Final output

Baseline hash, waves run, commits (subject plus SHA) with the boundary rationale for each, files modified, simplifications by category, remaining hotspots, and a final maintainability rating.
