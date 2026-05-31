---
description: "Use always: keep code, human docs, and AI customization docs minimal, clear, and maintainable; prefer simplification over cleverness and invoke the maintainability subagent for broad cleanup work."
name: "Maintainability"
applyTo: "**"
---

Default operating rule:

- Prioritize long-term human maintainability over short-term cleverness.
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

When modifying guidance files (`AGENTS.md` and `.agents/**`):

- Preserve a clear hierarchy: durable root guidance, focused specialized files.
- Ensure each rule is testable or verifiable in practice.
- Remove stale or speculative guidance instead of preserving it "just in case".
- Keep examples short and realistic.

Subagent collaboration:

- For broad maintainability cleanup, instruction consolidation, or architecture simplification spanning multiple files, invoke the `maintainability` subagent.
- Also invoke it when requested explicitly by a human.
- If task scope is small and clear, apply these rules directly without delegation.

Decision test before finalizing any change:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?

If any answer is "no", simplify again before final output.
