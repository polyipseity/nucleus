---
description: "Use always: aggressively simplify code, human docs, and AI customization docs; prefer deletion over abstraction; enforce atomic commits and parallel multi-pass maintainability subagent runs for broad cleanup."
name: "Maintainability"
applyTo: "**"
---

Default operating rule:

- Prioritize long-term human maintainability over short-term cleverness.
- Be aggressive about removing complexity, duplication, and stale guidance.
- Keep changes as small and local as possible.
- Prefer deleting complexity to adding abstractions.
- Write for future maintainers who did not author the original code.

Scope this rule applies to:

- Source code and automation scripts.
- Human-facing docs (`README.md`, host manuals, runbooks, comments).
- AI-facing docs (`AGENTS.md`, `.agents/instructions/**`, `.agents/prompts/**`, skill docs).

Maintainability constraints:

- Keep docs and instruction files concise, concrete, and scannable.
- Avoid policy duplication across files; link to the canonical source instead.
- Use narrow, purpose-driven files instead of large omnibus documents.
- Prefer explicit naming and straightforward control flow over indirection.
- Minimize hidden coupling and surprising behavior.
- Do not introduce complexity unless a concrete requirement demands it.

Git safety and commit discipline:

- At the start of maintainability work, capture a baseline commit hash (`git rev-parse HEAD`).
- Commit frequently in atomic slices (one aspect per commit) with clear, specific commit messages.
- Prefer many small reversible commits over large mixed commits.
- Never revert/reset/cherry-pick to a commit earlier than the captured baseline hash.
- If rollback is needed, roll back only to the baseline hash or newer.

When modifying guidance files (`AGENTS.md` and `.agents/**`):

- Preserve a clear hierarchy: durable root guidance, focused specialized files.
- Ensure each rule is testable or verifiable in practice.
- Remove stale or speculative guidance instead of preserving it "just in case".
- Keep examples short and realistic.

Subagent collaboration:

- For broad maintainability cleanup, instruction consolidation, or architecture simplification spanning multiple files, invoke the `maintainability` subagent.
- For high-complexity cleanup, run multiple `maintainability` subagents in parallel on independent scopes.
- Run multiple passes; after each pass, merge findings and launch another parallel pass for remaining hotspots until diminishing returns.
- Also invoke it when requested explicitly by a human.
- If task scope is small and clear, apply these rules directly without delegation.

Decision test before finalizing any change:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?

If any answer is "no", simplify again before final output.
