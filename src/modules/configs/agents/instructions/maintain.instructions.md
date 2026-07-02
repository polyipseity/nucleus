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

## Investigation protocol

When investigating a bug or unexpected behavior:

1. Trace the full call chain from entry point to leaf operations.
2. Enumerate all plausible root causes before diving into any single one.
3. For each cause, produce concrete evidence (log lines, error output, observed values) — do not reason from assumptions.
4. Report findings with evidence before proposing fixes.
5. Propose the simplest fix that addresses the confirmed root cause.

## Atomic commit workflow (unstaged changes → multiple commits)

When you have a set of unstaged changes and need to split them into multiple atomic commits, use this stash-first workflow.

1. **Format first** — Run the repo formatter so the working tree matches what the pre-commit hook will produce during `git commit`. This prevents merge conflicts when the stash (pre-format snapshot) is popped against hook- formatted files.
   ```bash
   prek run --stage pre-commit --all-files
   ```
   If that is unavailable, run formatters manually:
   ```bash
   cargo fmt && prek run end-of-file-fixer trailing-whitespace rumdl-fmt --all-files
   ```
2. `git stash` — save everything, get a clean working tree.
3. `git stash list` — note the stash reference (e.g. `stash@{0}`).
4. For each atomic commit you want to create: a. `git stash pop` — restore all remaining stashed changes to the working tree. b. `git add -p` (or `git add <specific-files>`) — stage **only** the changes that belong to this commit. Use interactive hunk selection if a single file contains changes for multiple commits. c. `git stash -u --keep-index` — stash everything that remains unstaged while keeping staged changes intact, so the pre-commit hook sees a clean working tree. d. `git commit -m "type(scope): precise message"` — commit only staged changes in a clean tree.
   - **If the commit fails because hooks modified staged files** (e.g., `cargo fmt` auto-fixed formatting): the hook-produced changes are now unstaged modifications. Stage them (`git add <modified-files>`) and retry step 4d. Do NOT retry without staging first — the hook will produce the same modifications and fail identically. e. `git stash list` — verify stash state is as expected.
5. After all commits are created, `git stash pop` any remaining leftovers.

### Hard rules

- **NEVER** rely on staged vs unstaged to separate changes across multiple commits. Pre-commit hooks (fmt, commitlint) may stash and pop, destroying the staged/unstaged boundary mid-flight.
- **NEVER** use `git commit --amend` while combining changes from multiple sources — it re-opens the last commit and interacts catastrophically with hook-driven stash/pop cycles.
- **ALWAYS** keep explicit track of the stash stack (`git stash list`) after every stash operation.
- **ALWAYS** use `git add -p` for fine-grained separation when one file has changes belonging to multiple commits.

Final check:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?
