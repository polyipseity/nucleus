---
description: "Use when disk space is low or an agent searches the filesystem. Covers the nucleus-only pause rule and the search-scope restriction."
name: "Resource Boundaries"
applyTo: "**"
alwaysApply: true
---

# Resource boundaries

## Disk space

In this repository, pause execution and stop when free space is below 1% or any command reports an out-of-space error. Do not clean, prune, or delete files in response. Report the failing command and `df -h` output; resume only after the owner frees space.

## Search scope

Run `find`, `rg`, `ls -R`, `tree`, or `git ls-files` only inside the current working directory or the directory the task targets. Never run these commands on `/`, `$HOME`, `~`, or a user directory. If a needed file lives outside the target tree, ask for its exact path.

Use skill paths supplied by the harness or task prompt. Do not discover skills by scanning user directories.
