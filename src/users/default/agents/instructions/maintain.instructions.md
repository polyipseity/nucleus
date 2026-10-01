---
description: "Use always: aggressively simplify code, human docs, and AI customization docs; prefer deletion over abstraction; enforce atomic commits and parallel multi-pass maintain subagent runs for broad cleanup."
name: "Maintainability"
applyTo: "**"
alwaysApply: true
---

Optimize for long-term human maintainability. Prefer deletion over abstraction, keep edits local and reversible, and remove duplication and stale guidance aggressively.

- Check `programming-principles.instructions.md` (Chesterton's Fence) before removing or changing legacy behavior.
- Keep one source of truth per policy, and keep rules testable and concrete.
- Every `|| true` needs an inline or preceding-line `# check-suppress:suppression_doc: reason` comment. Remove speculative guidance instead of preserving it.

## execution

1. Capture the baseline hash (`git rev-parse HEAD`).
2. Attack the highest friction first: duplication, indirection, stale docs.
3. Apply the smallest coherent simplification that improves clarity.
4. Validate behavior still matches intent.
5. Commit in atomic slices with precise messages.
6. Run the changed code path and check the output. Compilation passing is not verification.

For multi-file cleanup, run `maintainer` subagents in parallel on independent lanes (max 2 concurrent), merge, then do another pass on the remaining hotspots. Stop when only cosmetic improvements are left.

Script simplification patterns for this repo are in `nix-and-script-authoring.instructions.md`.

## git safety

- Never ask a subagent to run git commit. The MAIN agent commits, so parallel agents cannot race the prek hooks.
- Never `git reset`, especially `--hard` or `--keep`. Use `git revert` or `git restore`.
- Never `git revert` or `git cherry-pick` earlier than the captured baseline hash.
- Never `git commit --amend` unless you just created the commit and verified `git rev-parse HEAD` and `git log -1 --format=%s` match your intent. `--amend` rewrites whatever HEAD points at.
- After any commit failure, check `git rev-parse HEAD`. Unchanged hash means the commit was not created: fix the cause and retry with a fresh `git commit`, never `--amend`. A hook that reformatted files means re-staging them first.
- Do not mix unrelated concerns in one commit.

`commit-safety.instructions.md` holds the full verification protocol. `~/.agents/prompts/commit-staged.prompt.md` holds the atomic commit workflow.

Before finishing, four questions: is this easier for a new maintainer, is it the simplest design that still meets the requirement, did complexity go down as much as it went up, and can a human find the source of truth fast?
