---
description: "Use when performing git commit operations. Covers commit verification, recovery from failure, amend prohibition, and concrete failure modes."
name: "Commit Safety"
applyTo: ".git/**"
globs: ".git/**"
alwaysApply: false
---

# Commit safety

## Verify every commit attempt

After EVERY `git commit` command (whether it succeeds or fails):

1. Run `git rev-parse HEAD` and `git log -1 --format=%s`.
2. Confirm the hash is new (different from before the attempt) and the message matches your intended message.
3. If the hash/message match the PREVIOUS commit (not the one you tried to create), the commit was NOT created. HEAD did not move.

## Recovery from a failed commit

When a commit fails (pre-commit hook, commitlint, etc.), the commit was NOT created. HEAD is still at whatever it was before the attempt.

Recovery steps:
1. **Read the hook output.** Identify the root cause.
2. **If an auto-formatting hook modified files**, re-stage them: `git add <files>`.
3. **If a lint/validation hook rejected the message**, fix the underlying issue. For commitlint: correct the message format (add type prefix, wrap lines at 72 chars).
4. **Retry with a FRESH `git commit`. NEVER use `git commit --amend`.**

## AMEND PROHIBITION — hard rule

`git commit --amend` is FORBIDDEN after a failed commit. It is also FORBIDDEN without positive verification that HEAD points to the commit you just created.

Why: a failed commit means HEAD did not move. `git commit --amend` modifies whatever HEAD currently points to — which is a pre-existing commit, not the one you tried to create. This destroys history by altering an existing commit.

The ONLY safe use of `git commit --amend`:
1. You just ran `git commit` and it SUCCEEDED (exit code 0).
2. You verified with `git rev-parse HEAD` that the hash is new.
3. You need to amend the message of that NEW commit.
4. You run `git commit --amend` to modify only that new commit.

After a commit failure: always retry with a fresh `git commit`. Never amend.

## Concrete failure modes

**Commitlint rejection:** The message format was rejected. The commit was not created. HEAD is still at the previous commit. Fix the message and retry: `git commit -m "type(scope): correct message"`. Do NOT use `--amend`.

**Auto-formatting hook (nixfmt, prettier):** The hook modified staged files. The commit was not created (hooks run before commit finalization). Re-stage: `git add <files>`, then retry with a fresh `git commit`.

**Blind retries waste time.** Hook failures always indicate a problem in staged content or a tool that modified it. Diagnose before re-attempting.

## Related instruction files

- `commit.instructions.md` — Pre-commit commitlint validation policy.
- `core-behavior.instructions.md` — Git commit enforcement policy and commit-keeper subagent delegation.
- `maintain.instructions.md` — Atomic commit workflow, safety rules, and git operation restrictions.
- `execution-details.instructions.md` — Tool recovery and multi-edit fallback after failed operations.
