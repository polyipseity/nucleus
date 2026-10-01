---
description: "Use when performing git commit operations. Covers commit verification, recovery from failure, amend prohibition, and concrete failure modes."
name: "Commit Safety"
applyTo: ".git/**"
globs: ".git/**"
alwaysApply: false
---

# Commit safety

## Verify every commit attempt

After every `git commit`, successful or not:

1. Run `git rev-parse HEAD` and `git log -1 --format=%s`.
2. Confirm the hash is new and the message is the intended one.
3. If hash and message match the previous commit, the commit was NOT created.

## Recovering from a failure

A failed commit means HEAD did not move. Read the hook output and find the root cause: an auto-formatting hook (nixfmt, prettier) that modified files needs a re-stage with `git add <files>`; a lint rejection needs the underlying issue fixed, for commitlint the message format (type prefix, wrapped lines).

Then retry with a fresh `git commit`. Never `--amend`.

## Amend prohibition

`git commit --amend` is forbidden after a failed commit, because HEAD still points at a pre-existing commit and amending it destroys history. It is only safe when all of these hold:

1. The `git commit` just ran and exited 0.
2. `git rev-parse HEAD` confirmed a new hash.
3. The amend touches only that new commit.

Failure modes worth knowing: a commitlint rejection leaves HEAD at the previous commit, so fix the message and retry (`git commit -m "type(scope): correct message"`); an auto-formatting hook modified staged files and the commit was never finalized, so re-stage and retry. Blind retries waste time, since a hook failure always points at staged content or a tool that changed it.
