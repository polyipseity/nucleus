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

Communication standard:

- Be direct, technical, and actionable.
- Avoid motivational padding, repeated plans, and redundant restatements.
- Prioritize correctness, traceability, and completion.
