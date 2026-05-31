---
name: maintainability
description: Aggressively improve maintainability via repeated parallel waves of maintainability subagents, with strict atomic commit discipline and rollback safety.
argument-hint: Optional scope (e.g., `target=src/modules/` or `target=docs/`). Default: entire codebase.
---

# Maintainability Improvement Loop

Aggressively remove unnecessary complexity across code, docs, and AI customizations. Preserve behavior.

## Workflow

1. Capture baseline hash with `git rev-parse HEAD`; never roll back earlier.
2. Resolve `${input:target}` to scope (default `**/*`).
3. Partition scope into independent lanes.
4. Run parallel `maintainability` subagents, one per lane, using:

   ```text
   Improve maintainability across {{LANE_SCOPE}}.
   Be aggressive: remove unnecessary indirection, duplicated policy,
   stale guidance, and avoidable abstractions.
   Preserve behavior.
   Report: (1) changes made with file paths, (2) simplifications applied,
   (3) remaining hotspots, (4) recommended atomic commit slices.
   ```

5. Merge lane results and commit in atomic slices.
6. Re-run another parallel wave for remaining hotspots.
7. Stop when all lanes are down to minor/cosmetic improvements.

## Constraints

- No speculative refactors.
- Preserve behavior and repository conventions.
- Keep commits small, coherent, and reversible.

## Final output

- Baseline hash.
- Waves run.
- Commits (subject + SHA) and boundary rationale.
- Files modified.
- Simplifications by category.
- Remaining hotspots.
- Final maintainability rating.
