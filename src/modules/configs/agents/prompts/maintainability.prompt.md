---
name: maintainability
description: Iteratively improve codebase maintainability by invoking the maintainability subagent repeatedly until high maintainability is achieved.
argument-hint: Optional scope (e.g., `target=src/modules/` or `target=docs/`). Default: entire codebase.
---

# Maintainability Improvement Loop

Systematically reduce unnecessary complexity and improve readability across the codebase, documentation, and AI customization files. Repeat until no significant improvements remain.

## Workflow

### 1. Initialize Scope

Parse optional input `${input:target}` to determine scope:

- If provided: scope to specific file, directory, or pattern (e.g., `src/modules/`, `*.nix`, `AGENTS.md`)
- If omitted: scope to entire workspace (`**/*`)

**Output**: Clearly state the scope being improved in this session.

### 2. Invoke Maintainability Subagent (Iteration 1)

Invoke the `maintainability` subagent with:

```
Improve maintainability across {{SCOPE}}.
Focus on: removing unnecessary complexity, consolidating duplication, simplifying documentation,
reducing hidden coupling, and making code/docs easier for humans to read and maintain.
Report: (1) changes made (with file paths), (2) simplifications applied, (3) remaining hotspots/pain points.
```

**Record output**:

- List of all simplifications (consolidations, deletions, rewrites)
- Files touched (with line ranges if available)
- Identified remaining complexity hotspots (backlog for next iteration)
- Estimated maintainability improvement (subjective: low/medium/high)

### 3. Termination Check (After Each Iteration)

Evaluate whether maintainability is now "highly improved":

**Continue if ANY of these conditions hold:**

- Subagent found and completed ≥5 meaningful simplifications in this iteration
- Remaining hotspots are substantial (multiple files, complex logic, deep nesting, duplicated patterns)
- Subagent identified specific categories of improvement still pending (e.g., "docs still sprawling", "module coupling remains high")

**Stop if ALL of these conditions hold:**

- Subagent found <3 meaningful simplifications in this iteration (diminishing returns)
- Remaining hotspots are minor (isolated edge cases, single-file concerns, cosmetic issues)
- Subagent reports: "Maintainability is now high; remaining issues are edge cases or out-of-scope"
- Estimated improvement rating is "medium" or lower (indicating plateau reached)

### 4. Iterate (Repeat if Continuing)

If continuing, invoke the maintainability subagent again with an updated scope:

```
Continue improving maintainability, focusing now on the remaining hotspots identified in the previous iteration:
{{PREVIOUS_HOTSPOTS}}

Apply the same simplification principles: remove complexity, consolidate duplication, clarify intent.
Report: (1) changes made, (2) new simplifications, (3) any remaining pain points.
```

**Record output** using the same format as Iteration 1.

Repeat steps 3–4 until termination condition is met.

### 5. Final Summary

When stopping, produce a comprehensive summary:

- **Total iterations**: N
- **Total files modified**: X (list them)
- **Total simplifications across all iterations**: Y (categorized by type: deletions, consolidations, rewrites, documentation improvements)
- **Complexity reduction**: Before/after (subjective assessment)
- **Remaining hotspots** (if any, for future work or explicit deferral)
- **Estimated maintainability rating**: Low / Medium / High (subjective based on complexity, clarity, duplication)

---

## Constraints

- **No speculative changes**: Every simplification must reduce genuine complexity or improve readability. Do not refactor for style alone.
- **Preserve behavior**: All changes must be pure simplifications—no logic changes, feature additions, or bug fixes.
- **Respect conventions**: Follow repository guidelines (naming, sorting, formatting) from `AGENTS.md` and `.agents/instructions/*.md`.
- **Atomic commits** (if applicable): Each iteration may produce one or more logical commits; preserve one-aspect-per-commit rule.

## Success Criteria

- Reduced nesting and cognitive load across touched files
- Eliminated duplicated guidance, patterns, or logic
- Shortened and clarified documentation (no wall-of-text sections)
- Simpler mental model for understanding the codebase
- Fewer hidden dependencies and surprising behaviors

End of prompt.
