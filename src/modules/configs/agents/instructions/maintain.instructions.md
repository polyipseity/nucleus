---
description: "Use always: aggressively simplify code, human docs, and AI customization docs; prefer deletion over abstraction; enforce atomic commits and parallel multi-pass maintain subagent runs for broad cleanup."
name: "Maintainability"
applyTo: "**"
---

Default rule: optimize for long-term human maintainability.

This file is the canonical maintainability policy text. Keep this as the single
source of truth; mode-specific files should stay concise and execution-focused.

- Prefer deletion over abstraction.
- Keep edits local, explicit, and reversible.
- Remove duplication and stale guidance aggressively.
- Preserve behavior unless the task explicitly requires behavior change.

Execution checklist:

1. Capture baseline hash at start (`git rev-parse HEAD`).
2. Find the highest-friction complexity first (duplication, indirection, stale docs).
3. Apply the smallest coherent simplification that materially improves clarity.
4. Validate behavior still matches intent.
5. Commit in atomic slices with precise messages.

Broad cleanup rule:

- For multi-file cleanup, run `maintain` subagents in parallel on independent lanes.
- Merge results, then run another parallel pass for remaining hotspots.
- Stop when only minor/cosmetic improvements remain.

Guidance-file rule (`AGENTS.md`, `.agents/**`):

- Keep one source of truth per policy.
- Keep rules testable and concrete.
- Remove speculative guidance instead of preserving it.

Safety rules:

- Never revert/reset/cherry-pick earlier than the captured baseline hash.
- Do not mix unrelated concerns in the same commit.

Final check:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?
