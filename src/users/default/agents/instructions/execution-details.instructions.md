---
description: "Use when debugging tool retries, structuring investigation of failures, or applying multi-edit recovery strategies."
name: "Execution Details and Tool Recovery"
applyTo: "**"
alwaysApply: true
---

# Execution details and tool recovery

## Tool-retry discipline

A malformed tool error repeats identically, so never retry the same pattern. Switch tools (`multi_replace_string_in_file` to `replace_string_in_file`), simplify the request, or restructure the approach. A failed batch edit recovers through sequential single-edit calls, with a smaller batch or simpler diffs rather than the same call again.

## Investigation protocol

1. Verify upstream behavior before reasoning about a third-party tool's internals: read its source, official docs, or man pages. Never reason about API semantics, config formats, or runtime errors from assumption.
2. Trace the whole call chain from entry point to leaf operation.
3. Enumerate every plausible root cause before investigating one.
4. Produce concrete evidence per cause: log lines, error output, observed values.
5. Report findings with evidence before proposing a fix, then fix the confirmed root cause with the simplest change.
