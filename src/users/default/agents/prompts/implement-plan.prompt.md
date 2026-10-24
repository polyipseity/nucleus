---
name: implement-plan
description: Execute an implementation plan with subagent parallelism and atomic commits.
disable-model-invocation: true
argument-hint: "[atomicCommits=yes|no] [backwardsCompat=yes|no] [maxConcurrency=N]"
---

# Implement plan

Read `~/.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `~/.agents/instructions/harness-adapters.reference.md`.

## Arguments

$@

Resolution order: explicit arguments, then the plan frontmatter `inputs`, then these defaults: `atomicCommits=yes`, `backwardsCompat=no`, `maxConcurrency=2`. Flags may appear in any order. State `Arguments loaded: atomicCommits=<value>, backwardsCompat=<value>, maxConcurrency=<value>` before any implementation begins.

## 1. Create the plan file

The plan lives in session memory as `plan-<datetime>.md` so it survives context compaction. Generate the name with `date -u +%Y-%m-%dT%H%M%S`, create it with the session memory write capability, then read it back to confirm it is nonempty and substantive rather than whitespace or a bare title. From then on, always retrieve it through the find-latest-plan pattern below instead of relying on ephemeral variables.

If the session memory capability is unavailable, stop and report it. Do not write the plan anywhere else.

Frontmatter:

```
---
status: in-progress
committed: no
current-step: 1
inputs:
  atomicCommits: yes
  backwardsCompat: no
  maxConcurrency: 2
---
```

`current-step` tracks the workflow step number below (1 to 5), never a plan phase number; phases are tracked by re-reading the plan body.

## 2. Implement

Retrieve the plan, parse the frontmatter `inputs`, and log the recovered values. Follow the plan's steps in order, simplifying code as you edit. With `backwardsCompat: no`, add no compat shims. When `atomicCommits` is `no`, perform no git operations at all.

### Atomic commits

With `atomicCommits: yes`, commit after every meaningful sub-step: adding a function, creating or modifying a file, completing a subagent's returned work, or finishing any unit of work the plan lists as a bullet. Verify the current change is committed before moving to the next step within a phase. When in doubt, commit: over-committing beats under-committing. Never batch unrelated changes into one commit.

Re-read the plan regularly, especially after interruptions, subagent returns, and context switches, so no phase is skipped or misread.

Before any context switch, subagent call, or natural break, update the frontmatter: retrieve the plan, bump `current-step` to the current workflow number, update `committed`, and write it back with the session memory update capability. Invoke the checkpoint skill (`skill: "checkpoint"`) alongside each update. `committed` goes `no` to `partial` on the first commit and stays `partial` after that; it becomes `yes` only in step 5, so "some commits" stays distinguishable from "all commits". With `atomicCommits: no`, leave it at `no`.

**Pre-subagent commit gate:** before spawning any subagent, commit the current phase's work. Never delegate with a dirty working tree, and update `committed` afterwards.

## 3. Delegate

Invoke the checkpoint skill first. Then enumerate the delegatable subproblems (separate files, independent phases, parallel research), write that list to session memory, and spawn a subagent for each: planning sub-steps, separate file implementations, research unknowns, or verification of intermediate results. Each gets a fresh context, which prevents overflow and the risk of forgetting earlier requirements. Pass the plan path so a subagent can read it. Use `~/.agents/prompts/delegate.prompt.md` for the template. Cap concurrency at `maxConcurrency`, and spawn subagents even at `maxConcurrency: 1`. Subagents follow the same step-by-step, no-filler style. Set `current-step` to 3 before spawning.

When a subagent returns: review its changes, commit them atomically with a message describing what it accomplished, then move to the next result. One subagent result per commit.

## 4. Verify completeness

Set `current-step` to 4, retrieve the plan, and re-read it. Every phase must be fully implemented. An empty plan file at this point means the plan was lost or corrupted: abort with a clear error rather than guessing the remaining work. Re-read the source context for any ambiguous phase, and never declare a skipped or partial phase complete.

With `atomicCommits: yes`, also check `git log --oneline -<number-of-phases>` and confirm each phase has a commit. Flag a phase with none and re-execute it.

## 5. Finalize

Set `status: completed` and `current-step: 5`, then write the frontmatter back. Do not delete the plan file: `continue`, `verify-plan`, and `verify-implementation` read it.

With `atomicCommits: yes` and `committed: no`, this is a FAILURE: log it, re-read the plan, re-execute from phase 1 under the commit rules, set `current-step` to 2 and keep `status: in-progress`. Do not mark completion. With `committed: partial`, set it to `yes`. With `atomicCommits: no`, leave it at `no`.

Close with what was implemented, which files changed, and any deferred items.

## Find the latest plan file

1. List session memory and pick the newest `plan-<datetime>.md` by name (descending datetime).
2. No match: report "no active plan found" and stop.
3. Read that plan file.
