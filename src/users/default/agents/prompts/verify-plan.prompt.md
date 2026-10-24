---
description: "Research the active plan (plan-*.md in session memory) using online searches to verify feasibility, accuracy, and risks before implementation."
disable-model-invocation: true
name: "verify-plan"
argument-hint: "[phase or file]"
---

# Verify plan with online research

Read `~/.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `~/.agents/instructions/harness-adapters.reference.md`. Do not edit any file, do not create any file, and do not run any git command.

## Focus

$@

Empty means: verify the whole plan. Research online, compare against the plan, and report.

## 1. Retrieve the plan

1. List session memory and pick the newest `plan-<datetime>.md` by name (descending datetime). None: report "No active plan found, nothing to verify." and stop.
2. Read that plan file.
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
