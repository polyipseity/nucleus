---
name: maintainability
description: Aggressively improve maintainability via repeated parallel waves of maintainability subagents, with strict atomic commit discipline and rollback safety.
argument-hint: Optional scope (e.g., `target=src/modules/` or `target=docs/`). Default: entire codebase.
---

# Maintainability Improvement Loop

Systematically and aggressively remove unnecessary complexity across code, human docs, and AI customization files. Run repeated parallel subagent waves until improvements plateau.

## Workflow

### 1. Capture Baseline and Scope

Before edits, capture and persist baseline commit hash:

```shell
git rev-parse HEAD
```

Treat this hash as the rollback floor for the entire run.

Hard rule: never revert/reset/cherry-pick to any commit older than this baseline.

Parse optional input `${input:target}` to determine scope:

- If provided: scope to specific file, directory, or pattern (e.g., `src/modules/`, `*.nix`, `AGENTS.md`)
- If omitted: scope to entire workspace (`**/*`)

**Output**: Clearly state the scope being improved in this session.

### 2. Partition Scope for Parallelism

Break scope into independent cleanup lanes (for example: core code paths, tests, docs, AI customization files). Keep lanes isolated to reduce merge conflicts.

### 3. Launch Parallel Subagent Wave (Pass 1)

Invoke multiple `maintainability` subagents in parallel, one per lane.

Use this prompt per lane:

```
Improve maintainability across {{LANE_SCOPE}}.
Be aggressive: remove unnecessary indirection, duplicated policy, stale guidance, and avoidable abstractions.
Preserve behavior.
Report: (1) changes made with file paths, (2) simplifications applied, (3) remaining hotspots, (4) recommended atomic commit slices.
```

### 4. Commit in Atomic Slices (Per Wave)

For each lane outcome:

- Apply edits in small coherent slices.
- Commit frequently (one aspect per commit).
- Use clear, specific commit messages describing the exact simplification.
- Keep unrelated edits out of the same commit.

### 5. Merge Results and Record Wave Output

Record for each wave:

- List of all simplifications (consolidations, deletions, rewrites)
- Commits created per lane (subject + SHA)
- Files touched
- Remaining hotspots backlog for next wave
- Estimated improvement per lane (low/medium/high)

### 6. Termination Check (After Each Wave)

Evaluate whether maintainability is now "highly improved":

**Continue if ANY of these conditions hold:**

- At least one lane produced ≥3 meaningful simplifications in this wave
- Remaining hotspots are substantial (multiple files, complex logic, deep nesting, duplicated patterns)
- Subagent identified specific categories of improvement still pending (e.g., "docs still sprawling", "module coupling remains high")

**Stop if ALL of these conditions hold:**

- All lanes produced <3 meaningful simplifications (diminishing returns)
- Remaining hotspots are minor (isolated edge cases, single-file concerns, cosmetic issues)
- Subagents report remaining work is edge-case or out-of-scope
- Overall improvement plateaus at "medium" or lower for a full wave

### 7. Iterate with Another Parallel Wave

If continuing:

- Repartition remaining hotspots into independent lanes.
- Launch another set of maintainability subagents in parallel.
- Repeat steps 4–7.

### 8. Final Summary

When stopping, provide:

- Baseline hash and confirmation no rollback went earlier
- Total waves run (parallel passes)
- Total subagent runs across all waves
- Total commits created and why each commit boundary was chosen
- Total files modified
- Total simplifications by category
- Remaining hotspots (if any)
- Final maintainability rating (low/medium/high)

---

## Constraints

- **No speculative changes**: Every simplification must reduce genuine complexity or improve readability. Do not refactor for style alone.
- **Preserve behavior**: All changes must be pure simplifications—no logic changes, feature additions, or bug fixes.
- **Respect conventions**: Follow repository guidelines (naming, sorting, formatting) from `AGENTS.md` and `.agents/instructions/*.md`.
- **Atomic commits**: Commit often and keep one coherent simplification per commit.
- **Rollback floor**: Never revert/reset/cherry-pick earlier than the recorded baseline hash.
- **Parallelism requirement**: Use parallel subagent waves for independent lanes; do not serialize independent cleanup work.

## Success Criteria

- Reduced nesting and cognitive load across touched files
- Eliminated duplicated guidance, patterns, or logic
- Shortened and clarified documentation (no wall-of-text sections)
- Simpler mental model for understanding the codebase
- Fewer hidden dependencies and surprising behaviors
- Clear, fine-grained commit history that enables safe targeted rollback

End of prompt.
