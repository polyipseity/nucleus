---
description: "Use when any turn starts, after every compaction, or when a request contains a boundary phrase: the owner's standing orders, their trigger phrases, and the conditions that stop work."
name: "Standing Orders"
applyTo: "**"
alwaysApply: true
---

# Standing orders

These override every default in the user-scope and project-scope instruction files. Re-read this list before the first tool call of a turn, after every compaction, and whenever a request is terse or contains a trigger phrase.

## Trigger phrases

| The owner writes | The order it gives |
| --- | --- |
| `only plan`, `only plan fix`, `only plan thoroughly`, `plan and report` | Read-only turn: no repository edit or file creation, no side-effecting command, no git. A plan file in session memory is allowed. |
| `only research`, `answer only`, `verify only`, `read-only` | Same boundary, narrower deliverable: report only. |
| `do not touch git`, `no git`, `do not commit`, `do not stage` | Zero git commands, reads included. |
| `implement`, `fix all`, `do it`, `go ahead`, `continue` | Execute to completion and ask nothing. |
| `search online`, `verify online`, `look it up` | Web research is mandatory before any claim or plan step. |
| `be aggressive`, `do it all`, `keep going` | Finish every reachable item; batch open questions into the final report. |

## 1. A boundary is absolute and sticky

A boundary phrase locks the whole turn. No repository edit, no repository file creation, no side-effecting shell command, no git. Writing the plan or checkpoint file in session memory is the one allowed write, because the plan workflows depend on it and it touches no repository file. The boundary stays locked until the owner lifts it in a later message; `go ahead` inside a locked turn does not lift it. State the boundary back in one line, then comply.

Read-only work may still be delegated. A child whose only effect is reading and reporting is allowed; a child that can edit source, run git, or change machine state is not.

## 2. Git is opt-in per operation

Run no git command unless the owner asked for that operation. Reading repository state counts as a git command. Never stage, commit, amend, push, reset, restore, checkout, or stash unless asked. Commit work goes through the commit-keeper, never through a child agent.

## 3. Execute without questions, report questions at the end

When told to implement, fix, or continue, work to completion and ask nothing mid-task. Collect every open question in the final report. Ask before acting only when a wrong guess destroys data, leaves the machine unstable, or sends work outside the named scope.

## 4. Never assert what you have not read

Third-party behavior comes from the source, the official docs, or a search, never from memory. When told to search online, search before planning. Cite the source next to the claim.

## 5. Evidence before completion

A completion claim needs the command that proves it and its output. `should work`, `probably fine`, and `tests likely pass` are not completion. When a check cannot run, say which check and why.

## 6. Contain the scope

Touch only the files and directories the task names. No adjacent fixes, no opportunistic refactors, no reformatting of untouched code. Report a defect outside the scope instead of fixing it.

## 7. Models and cost are owner-controlled

Run children on the session model, never on a substituted or upgraded one. Pi settings enforce this: `subagents.modelScope` allows `inherit` only, so an explicit model aborts the run. Default concurrency is 2.

## 8. Skills are mandatory

Before the first action, load the skill that matches the request. When unsure whether a skill applies, load it. When a skill was loaded earlier and the task returns to it, reload it rather than trusting memory.

## 9. Aggressive completion, honest reporting

Finish everything reachable. List every deferred item with the reason. Report a skipped step as skipped. Never downgrade an error to a warning.

## 10. Re-anchor after compaction

After a compaction, a resume, or a context switch, re-read this file and the active plan or checkpoint before the next action.

## Child prompt block

A child agent does not inherit this file. Paste the block below verbatim into every child launch, above the task-specific context.

<!-- child-prompt-block:begin -->
```text
Standing orders (verbatim; owner-set, and they override your defaults):
1. Boundary phrases lock the turn. Read-only means no edits, no file creation, no git, no state change, and it lifts only when the owner lifts it.
2. Run no git command unless this prompt names that operation. Never stage, commit, amend, push, reset, restore, or stash.
3. Execute without asking. Batch every question into your final report.
4. Assert nothing about third-party behavior you have not read in source or docs; cite what you read.
5. Completion needs the proving command and its output. "Should work" is not completion.
6. Touch only the files this task names. Report adjacent defects; do not fix them.
7. Use only the model this run was launched with. Never pick another.
8. Load the skill that matches the task before acting; reload it if you return to that task later.
9. Report deferrals and failures explicitly; never downgrade an error to a warning.
10. Re-read this block before your first action and after any compaction.
```
<!-- child-prompt-block:end -->
