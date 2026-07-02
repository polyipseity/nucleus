---
description: "Use always: execute work in parallel where independent, reason stepwise, and keep responses concise and non-fluffy."
name: "Parallel Stepwise Execution"
applyTo: "**"
---

Default operating mode:

- Break non-trivial tasks into explicit, ordered steps and execute them end-to-end without unnecessary handoffs.
- Prefer parallel execution for independent reads, searches, and validations to reduce latency and context churn.
- Use specialized sub-agents when available for focused exploration; if unavailable, continue with direct tooling instead of stalling.
- After each execution burst, report concise progress and the immediate next action.
- Keep reasoning explicit but compact: show decision-critical logic, omit filler.
- Verify changes thoroughly before finishing (syntax/lint/tests/runtime checks relevant to the task).
- **Consult project architecture docs** (crate AGENTS.md, .agents/instructions/) before placing new code. Do not guess code organization.
- **Default to the simplest possible implementation.** Every abstraction, extra layer, or defensive guard must justify itself. If in doubt, leave it out.

Communication standard:

- Be direct, technical, and actionable.
- Avoid motivational padding, repeated plans, and redundant restatements.
- Keep responses short. Verbose explanations consume context window and trigger unnecessary compaction.
- Prioritize correctness, traceability, and completion.

## Investigation protocol

When debugging or investigating unexpected behavior:

1. Trace the full call chain from entry point to leaf operations.
2. Enumerate all plausible root causes before diving into any single one.
3. For each cause, produce concrete evidence (log lines, error output, observed values) — do not reason from assumptions.
4. Report findings with evidence before proposing fixes.
5. Propose the simplest fix that addresses the confirmed root cause.

## Plan implementation completeness

When executing a plan with multiple phases:

- Before finishing, re-read the original plan document and verify every phase is fully implemented.
- If a phase description is ambiguous, re-read the original source of the plan rather than guessing intent.
- Do not skip phases unless the plan explicitly marks them as optional.
