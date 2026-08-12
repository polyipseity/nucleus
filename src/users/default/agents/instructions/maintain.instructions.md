---
description: "Use always: aggressively simplify code, human docs, and AI customization docs; prefer deletion over abstraction; enforce atomic commits and parallel multi-pass maintain subagent runs for broad cleanup."
name: "Maintainability"
applyTo: "**"
alwaysApply: true
---

Default rule: optimize for long-term human maintainability.

This file is the canonical maintainability policy text. Keep this as the single source of truth; mode-specific files should stay concise and execution-focused.

- Prefer deletion over abstraction.
- Keep edits local, explicit, and reversible.
- Remove duplication and stale guidance aggressively.
- **See `programming-principles.instructions.md` (Chesterton's Fence)** before removing or changing legacy behavior.

Execution checklist:

1. Capture baseline hash at start (`git rev-parse HEAD`).
2. Find the highest-friction complexity first (duplication, indirection, stale docs).
3. Apply the smallest coherent simplification that materially improves clarity.
4. Validate behavior still matches intent.
5. Commit in atomic slices with precise messages.
6. **Verify actual behavior** — run the changed code path and check the output. Compilation is not sufficient; ensure the change produces the intended user-visible effect.

Broad cleanup rule:

- For multi-file cleanup, run `maintainer` subagents in parallel on independent lanes (max 2 concurrent).
- Merge results, then run another parallel pass for remaining hotspots.
- Stop when only minor/cosmetic improvements remain.

For repo-specific script simplification patterns, see the repo's `scripts-and-permissions.instructions.md`.

Guidance-file rule (`AGENTS.md`, `.agents/**`):

- Keep one source of truth per policy.
- Keep rules testable and concrete.
- Every `|| true` must be justified with an inline or preceding-line `# check-suppress:suppression_doc: reason` comment. Undocumented `|| true` is a violation.
- Remove speculative guidance instead of preserving it.

Safety rules:

- NEVER ask subagents to run git commit. Commit MUST be done by the MAIN agent to prevent race conditions.
- NEVER use `git reset` (especially `--hard` or `--keep`) under any circumstance. It destroys uncommitted work and can wipe days of progress. Use `git revert` or `git restore` instead.
- Never use `git commit --amend` without verification. `--amend` does not create a new commit — it merges staged changes into the current HEAD commit instead. Only use it when you can positively verify that HEAD is the commit you just created: run `git rev-parse HEAD` and `git log -1 --format=%s` and confirm both match your intent. If you cannot verify (e.g. after a failed commit where HEAD is still the previous commit), retry with a fresh `git commit`. Never modify pre-existing commits. NEVER use `git commit --amend` as a retry mechanism after a failed commit.
- **After ANY commit failure (pre-commit hook, commitlint, etc.), verify HEAD has not moved.** Run `git rev-parse HEAD`. If the hash matches the commit before the attempt, the commit was NOT created. Retry with a fresh `git commit`, never with `--amend`.
- **Commitlint recovery example:** Commit rejected with "subject may not be empty" or "no type prefix" — the commit was not created. Fix the message and retry: `git commit -m "type(scope): correct message"`. Do NOT use `git commit --amend` — that would modify the previous commit, not the failed one.
- Never revert or cherry-pick earlier than the captured baseline hash.
- Do not mix unrelated concerns in the same commit.
- See `commit-safety.instructions.md` for the full commit verification protocol and amend prohibition.

## Atomic commit workflow

See `~/.agents/prompts/commit-staged.prompt.md` for the canonical stash-based atomic commit workflow. The hard rules there (verify with `git rev-parse HEAD`, never trust terminal output) also apply here.

Final check:

1. Is this easier for a new maintainer to read and modify?
2. Is this the simplest design that still meets the requirement?
3. Did we remove at least as much complexity as we added?
4. Can a human quickly locate the source of truth?

## Related instruction files

- `core-behavior.instructions.md` — Subagent delegation patterns, git boundary rules, and immutable-by-default enforcement.
- `commit-safety.instructions.md` — Commit verification protocol, amend prohibition, and failure recovery.
- `execution-details.instructions.md` — Tool recovery and multi-edit fallback strategies.
