---
description: "Research the active plan (plan-*.md in session memory) using online searches to verify feasibility, accuracy, and risks before implementation."
name: "verify-plan"
argument-hint: "optional: specific phase, file, or question to focus research on"
---

# Verify plan with online research

You are in verification mode. Research the active plan using online searches to check feasibility, accuracy, dependencies, and risks. Do NOT execute, implement, or edit any files — only research, compare, and report.

## Guard clause

If the user's message that triggered this prompt contains "implement", "do it", "go ahead", "execute", "make the changes", or any equivalent execution indicator, refuse and redirect: "I'm in verify mode — I can only research and plan. To execute, use the implement-plan prompt."

## Workflow

### 1. Retrieve the plan

> **Memory tool availability:** If the `memory` tool is not in the available tool list, call `activate_vs_code_interaction` with no arguments first — it is a one-shot call that permanently unlocks VS Code interaction tools.

1. Find the latest plan file:
   - Use `memory view /memories/session/` to list session memory files.
   - Find the most recent `plan-*.md` by sorting names (descending datetime).
   - If no files match, report: "No active plan found — nothing to verify." and stop.
2. Read the plan file using `memory view /memories/session/<filename>`.
3. Parse the frontmatter for context (`status`, `current-step`, `committed`).
4. Parse `inputs` from frontmatter. Record `atomicCommits`, `backwardsCompat`, `maxConcurrency` for awareness — not used during verification but helpful context for the report.
5. Find and load the latest checkpoint for supplementary context:
   - Use `memory view /memories/session/` to list session files. Find the most recent `checkpoint-*.md` by sorting names (descending datetime).
   - If a checkpoint exists, read it using `memory view /memories/session/<filename>` — the checkpoint's "Work done" and "Next steps" sections provide rich verification context (what was just implemented, what files were touched, pending decisions).
   - If no checkpoint exists, proceed without it.

### 2. Research each phase and step

For every phase and step in the plan, determine what needs verification and search accordingly.

**Search sources and priority:**

1. **GitHub** — search for libraries, APIs, tool docs, code examples, issues, changelogs, and compatibility info.
2. **DuckDuckGo** — general web search for docs, tutorials, known issues, and best practices.
3. **Other search engines or websites the model knows** — official documentation sites, package registries, specialized forums.

**What to research per step:**

- **Library/API/tool usage**: Check docs, changelogs, deprecation notices, breaking changes, and correct API signatures.
- **Package availability**: Verify the package exists, correct name, latest version, and platform support.
- **Code examples or patterns**: Find idiomatic approaches and known pitfalls.
- **Configuration syntax**: Verify config file formats, schemas, valid values, and defaults.
- **Dependencies and compatibility**: Check version constraints, transitive deps, and platform requirements.
- **Alternatives and trade-offs**: Research whether a simpler or more robust approach exists.
- **Risks or known issues**: Look for open bugs, regressions, or security advisories related to the step.

**Log each finding** — for every step, record what was checked and the result (verified, issues found, or uncertain).

### 3. Report or approve

**If all steps check out:**

- Report: "Plan verified — no issues found."
- Optionally include a summary of what was researched.

**If issues are found:**

- Report which steps have problems with specific evidence (include URLs or search result summaries).
- Classify each issue:
  - **Blocking** — will prevent implementation from working correctly.
  - **Risky** — may cause problems; should be mitigated.
  - **Informational** — worth knowing but not blocking.
- **Do NOT implement fixes.** Instead, produce recommendations for plan updates.
- Recommend updating the plan (adding steps, changing approaches, swapping dependencies) before proceeding to implement-plan.

### 4. Output format

**Success output:**

```
## Verification result: OK

Plan "<title>" verified — no issues found.

### What was checked
- Phase 1: <summary> — verified
- Phase 2: <summary> — verified
```

**Issues found output:**

```
## Verification result: Issues found

Plan "<title>" has <N> issue(s) that should be addressed before implementation.

### 🔴 Blocking
- Phase <N>, step <M>: <description> — <evidence>

### 🟡 Risky
- Phase <N>, step <M>: <description> — <evidence>

### 🔵 Informational
- Phase <N>, step <M>: <description> — <evidence>
```
