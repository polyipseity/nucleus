---
name: fuse-memories
description: "Use when: user says 'absorb memories', 'fuse memories', 'merge memories into instructions', or asks to persist session/repo/user memory into agent instructions. Merges selected memory files into repo or user .instructions.md files and deletes the originals."
disable-model-invocation: true
argument-hint: "[scope=...] [memoryName=...] [target=repo|user]"
---

# Fuse memories into agent instructions

Read `.agents/instructions/standing-orders.instructions.md` and follow it; it overrides this workflow's defaults. Resolve capability names through `.agents/instructions/harness-adapters.reference.md`.

Proceed automatically with defaults. No confirmation, no clarification.

## Arguments

$@

Read flags anywhere in the arguments: `scope=session,repo`, `memoryName=<names|all>`, `target=repo|user`. Defaults are those values. `scope` and `memoryName` are AND-ed: only memories matching both are selected, and `memoryName=all` means no name filter. `target` names the destination instruction directory: `repo` for `.agents/instructions/`, `user` for `~/.agents/instructions/`.

Resolve memory locations through the adapter reference. A scope the adapter marks unsupported is skipped with a one-line notice; never map it onto another scope.

## Probe

Scan the memory listing the running harness surfaces for filenames, filter by the resolved `memoryName` unless it is `all`, then list the active scopes with the session memory read capability. Fail closed: zero files means report "No memory files found at the resolved scopes. Aborting." and stop.

## Read

Read each confirmed memory file with the session memory read capability, and read every `.instructions.md` file at the target in full, recording each `##` section heading and its line range.

## Evaluate

Break each memory file into atomic facts and judge each one:

| Signal | Method |
|--------|--------|
| Codebase contradiction | Search the codebase for the claim; current code contradicting it means outdated |
| Reference death | Check the referenced files, functions, and commands still exist |
| Instruction supersession | A current `.instructions.md` already covers the topic authoritatively |
| Git timestamps (optional, costly) | `ls -l` on the resolved memory file where the adapter exposes a path; skip the column when it does not |
| Ambiguous | Cannot be verified or falsified against the workspace |

Verdicts: **current** absorbs, **discard** removes (provably wrong), **update** corrects then absorbs, **ignore** discards (outdated but harmless), **uncertain** discards (unverifiable). Print the verdict per fact before acting.

## Absorb

Only **current** and **update** facts proceed. Match each to the target file by topic keywords, then to a specific section where one fits. A fact spanning several topics gets split across files or sections.

Place rather than append: rewrite the matching paragraph inline, add a bullet to an existing list in the right position, add one short paragraph or bullet at the end of a relevant section, and only as a last resort add a section at the end of `core-behavior.instructions.md`.

Order the edits: plan all of them across all memory and instruction files in one pass, group by target file, order bottom-up within each file so line numbers hold, then apply each file's edits in a single file edit call.

## Delete

Delete every specified memory file with session memory delete. The file has served its purpose: absorbed facts now live in the instruction files and the rest were not worth preserving. When an edit in the previous step failed, keep the file and report the failure instead.

## Verify

Re-read each modified instruction file and confirm the facts are present and accurately expressed. Prune any fact now stated twice in the same file, keeping the better-placed instance. Check the voice: it should read as if the knowledge was always there, with no transitions and no memory dumps.

## Rules

- Prefer modifying existing content over adding new, and a new bullet over a new list.
- Never dump memories verbatim. Rephrase into the target file's voice.
- Skip a memory that is already fully covered.
- No editorial markers such as "Added from memory:" or "Note:".
