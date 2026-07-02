---
description: "Use always: aggressively simplify code, human docs, and AI customization docs; prefer deletion over abstraction; enforce atomic commits and parallel multi-pass maintain subagent runs for broad cleanup."
name: "Maintainability"
applyTo: "**"
---

Default rule: optimize for long-term human maintainability.

This file is the canonical maintainability policy text. Keep this as the single source of truth; mode-specific files should stay concise and execution-focused.

- Prefer deletion over abstraction.
- Keep edits local, explicit, and reversible.
- Remove duplication and stale guidance aggressively.
- Preserve behavior unless the task explicitly requires behavior change.

Execution checklist:

1. Capture baseline hash at start (`git rev-parse HEAD`).
2. Find the highest-friction complexity first (duplication, indirection, stale docs).
3. Apply the smallest coherent simplification that materially improves clarity.
4. Validate behavior still matches intent.
5. Commit in atomic slices with precise messages.
6. **Verify actual behavior** — run the changed code path and check the output. Compilation is not sufficient; ensure the change produces the intended user-visible effect.

Broad cleanup rule:

- For multi-file cleanup, run `maintain` subagents in parallel on independent lanes.
- Merge results, then run another parallel pass for remaining hotspots.
- Stop when only minor/cosmetic improvements remain.

Guidance-file rule (`AGENTS.md`, `.agents/**`):

- Keep one source of truth per policy.
- Keep rules testable and concrete.
- Remove speculative guidance instead of preserving it.

Safety rules:

- NEVER ask subagents to run git commit. Commit MUST be done by the MAIN agent to prevent race conditions.
- NEVER use `git reset` (especially `--hard` or `--keep`) under any circumstance. It destroys uncommitted work and can wipe days of progress. Use `git revert` or `git restore` instead.
- Never revert or cherry-pick earlier than the captured baseline hash.
- Do not mix unrelated concerns in the same commit.

## Atomic commit workflow (unstaged changes → multiple commits)

When you have a set of unstaged changes and need to split them into multiple atomic commits, use this primary workflow:

1. **Format first** — Run the repo formatter so the working tree matches what the pre-commit hook will produce during `git commit`.
   ```bash
   prek run --stage pre-commit --all-files
   ```
   If that is unavailable, run formatters manually:
   ```bash
   cargo fmt && prek run end-of-file-fixer trailing-whitespace rumdl-fmt --all-files
   ```
2. **For each atomic commit**:
   a. Stage only the changes for this commit: `git add -p` for selective hunk staging, or `git add <specific-files>` for whole-file commits.
   b. Commit directly: `git commit -m "type(scope): precise message"`. Pre-commit hooks run during the commit. If a hook exits non-zero, the commit is aborted — no commit is created, regardless of what terminal output suggests. If hooks succeed but modify staged files, stage the adjustments and retry the commit.
   c. **Verify commit**: Run `git rev-parse HEAD` and confirm it differs from the hash before the commit. Terminal output is not authoritative — only a changed HEAD confirms the commit landed.

### Stash-based fallback (when git add -p conflicts with pre-commit hooks)

If the direct approach fails because pre-commit hooks stash/pop and destroy the staged/unstaged boundary, use this stash-first workflow:

1. `git stash` — save everything.
2. `git stash list` — note the stash reference (e.g. `stash@{0}`).
3. For each atomic commit:
   a. `git stash pop` — restore all remaining stashed changes.
   b. `git add -p` (or `git add <specific-files>`) — stage **only** the changes for this commit.
   c. `git stash -u --keep-index` — stash remaining unstaged changes while keeping staged changes intact.
   d. `git commit -m "type(scope): precise message"` — commit in a clean tree. Hook failure semantics apply (step 2b). Afterward, verify with `git rev-parse HEAD`.
   e. `git stash list` — verify stash state.
4. After all commits, `git stash pop` any remaining leftovers.

### Hard rules

- **NEVER** rely on staged vs unstaged to separate changes across multiple commits. Pre-commit hooks (fmt, commitlint) may stash and pop, destroying the staged/unstaged boundary mid-flight.
- **NEVER** use `git commit --amend` while combining changes from multiple sources — it re-opens the last commit and interacts catastrophically with hook-driven stash/pop cycles.
- **ALWAYS** keep explicit track of the stash stack (`git stash list`) after every stash operation.
- **ALWAYS** use `git add -p` for fine-grained separation when one file has changes belonging to multiple commits.
- **Hook failure aborts the commit.** If any pre-commit hook exits non-zero, `git commit` creates nothing — never assume it succeeded because terminal output looked normal.
- **Never trust terminal output for commit confirmation.** Only `git rev-parse HEAD` (or `git log --oneline -1`) confirming a new commit is authoritative. Terminal messages from hooks or git are not reliable.

Final check:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?
