---
description: "Research the active plan (plan-*.md in session memory) using online searches to verify feasibility, accuracy, and risks before implementation."
disable-model-invocation: true
name: "verify-plan"
argument-hint: "optional: specific phase, file, or question to focus research on"
---

# Verify plan with online research

Research the active plan against online sources to check feasibility, accuracy, dependencies, and risks. Do NOT execute, implement, or edit any files: research, compare, report.

## Guard clause

If the triggering message contains "implement", "do it", "go ahead", "execute", "make the changes", or any equivalent, refuse and redirect: "I'm in verify mode: I can only research and plan. To execute, use the implement-plan prompt."

If the `memory` tool is missing from the tool list, call `activate_vs_code_interaction` with no arguments first: it is a one-shot call that unlocks the VS Code interaction tools.

## 1. Retrieve the plan

1. `memory view /memories/session/` and pick the newest `plan-*.md` by name (descending datetime). None: report "No active plan found, nothing to verify." and stop.
2. Read it with `memory view /memories/session/<filename>`.
3. Parse the frontmatter (`status`, `current-step`, `committed`, `inputs`) for context.
4. Load the newest `checkpoint-*.md` from the same listing for supplementary context. None is fine.

## 2. Research each step

Decide what needs verifying per step and search accordingly. Sources in priority order: GitHub for libraries, APIs, tool docs, code examples, issues, changelogs, and compatibility; DuckDuckGo for general docs, tutorials, known issues, best practices; other sources the model knows for official documentation, package registries, and specialist forums.

Per step, check: library/API/tool usage including docs, deprecations, breaking changes, and correct signatures; package availability including name, latest version, and platform support; idiomatic examples and known pitfalls; config syntax, schemas, valid values, and defaults; version constraints, transitive deps, and platform requirements; whether a simpler alternative exists; open bugs, regressions, and security advisories.

Log every step as verified, issues found, or uncertain, with the evidence.

## 3. Report

Clean: "Plan verified, no issues found.", optionally with what was researched.

With issues: name each problem with its evidence (URLs or search summaries) and classify it as blocking (implementation will not work correctly), risky (may cause problems, should be mitigated), or informational (worth knowing, not blocking). Do NOT implement fixes. Recommend the plan updates needed before running implement-plan.

## Output format

```
## Verification result: OK

Plan "<title>" verified, no issues found.

### What was checked
- Phase 1: <summary>: verified
- Phase 2: <summary>: verified
```

```
## Verification result: Issues found

Plan "<title>" has <N> issue(s) that should be addressed before implementation.

### Blocking
- Phase <N>, step <M>: <description>: <evidence>

### Risky
- Phase <N>, step <M>: <description>: <evidence>

### Informational
- Phase <N>, step <M>: <description>: <evidence>
```
