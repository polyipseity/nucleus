---
description: "Use when disk space is low or an agent searches the filesystem."
name: "Resource Boundaries"
applyTo: "**"
alwaysApply: true
---

# Resource boundaries

## Disk space

Pause and stop when free space is below 1% or a command reports out of space. Do not clean, prune, or delete in response. Report the failing command and `df -h` output; resume only after the owner frees space.

## Search scope

Run `find`, `rg`, `ls -R`, `tree`, or `git ls-files` only inside the current working directory or the task target. Never run them on `/`, `$HOME`, `~`, or a user directory. Ask for an exact path when a needed file is outside the target tree.

Use skill paths supplied by the harness or task prompt. Do not discover skills by scanning user directories.
