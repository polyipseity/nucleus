---
description: "Use when debugging tool retries, structuring investigation of failures, or applying multi-edit fallback strategies."
name: "Execution Details and Tool Recovery"
applyTo: "**"
alwaysApply: true
---

# Execution details and tool recovery

## Multi-edit fallback

When a batch edit tool call fails (e.g., `multi_replace_string_in_file`), fall back to sequential single-edit calls. Do not retry the same multi-edit call without adjusting the approach (smaller batch size, simpler diffs, or sequential replacements).

## Tool-retry discipline

When a tool call fails with a malformed error, do not retry the same pattern — it will produce the same error and burn context. Switch tools (e.g., `multi_replace_string_in_file` → `replace_string_in_file`), simplify the request, or restructure the approach.

## Investigation protocol

When investigating a bug or unexpected behavior:

1. **Verify upstream behavior first.** Before reasoning about a third-party tool's internals, consult its source code, official documentation, or man pages. Fabricated upstream behavior (API semantics, config formats, runtime errors) is not acceptable.
2. Trace the full call chain from entry point to leaf operations.
3. Enumerate all plausible root causes before diving into any single one.
4. For each cause, produce concrete evidence (log lines, error output, observed values) — do not reason from assumptions.
5. Report findings with evidence before proposing fixes.
6. Propose the simplest fix that addresses the confirmed root cause.

## Related instruction files

- `core-behavior.instructions.md` — General agent behavior model, investigation trigger points, and error handling conventions.
- `programming-principles.instructions.md` — Fail-fast principle, defensive boundaries, and railway-oriented error propagation patterns.
