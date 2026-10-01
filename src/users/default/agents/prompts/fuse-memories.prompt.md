---
name: fuse-memories
description: "Use when: user says 'absorb memories', 'fuse memories', 'merge memories into instructions', or asks to persist session/repo/user memory into agent instructions. Merges selected memory files into repo or user .instructions.md files and deletes the originals."
disable-model-invocation: true
argument-hint: "scope=session,repo | memoryName= | target=repo"
---

# Fuse memories into agent instructions

Proceed automatically with defaults. No confirmation, no clarification.

## Inputs

| Input | Default | Values |
|-------|---------|--------|
| `${input:scope}` | `session,repo` | Comma-separated from `session`, `repo`, `user` |
| `${input:memoryName}` | (all) | Comma-separated filenames without `.md`; omit for all in scope |
| `${input:target}` | `repo` | `repo` for `.agents/instructions/`, `user` for `~/.agents/instructions/` |

`scope` and `memoryName` are AND-ed: only memories matching both are selected.

Memory paths: `session` is `/memories/session/<name>.md`, `repo` is `/memories/repo/<name>.md`, `user` is `/memories/<name>.md`.

If the `memory` tool is not in the tool list, call `activate_vs_code_interaction` with no arguments first: it is a one-shot call that unlocks the VS Code interaction tools. Discover memory files with `memory view /memories/<scope>/`, never with `list_dir`, `file_search`, or `resolve_memory_file_uri`.

## Probe

Scan the `<repoMemory>` and `<sessionMemory>` context blocks for filenames, filter by `${input:memoryName}` when set, then list the active scopes with `memory view /memories/<scope>/`. Fail closed: zero files means report "No memory files found at scopes `${input:scope}`. Aborting." and stop.

## Read

Read each confirmed memory file with `memory view`, and read every `.instructions.md` file at the target in full, recording each `##` section heading and its line range.

## Evaluate

Break each memory file into atomic facts and judge each one:

| Signal | Method |
|--------|--------|
| Codebase contradiction | Search the codebase for the claim; current code contradicting it means outdated |
| Reference death | Check the referenced files, functions, and commands still exist |
| Instruction supersession | A current `.instructions.md` already covers the topic authoritatively |
| Git timestamps (optional, costly) | `ls -l` on the resolved URI, which `resolve_memory_file_uri` is valid for here since the target is a terminal command; a memory predating changes to the code it references is likely outdated |
| Ambiguous | Cannot be verified or falsified against the workspace |

Verdicts: **current** absorbs, **discard** removes (provably wrong), **update** corrects then absorbs, **ignore** discards (outdated but harmless), **uncertain** discards (unverifiable). Print the verdict per fact before acting.

## Absorb

Only **current** and **update** facts proceed. Match each to the target file by topic keywords, then to a specific section where one fits. A fact spanning several topics gets split across files or sections.

Place rather than append: rewrite the matching paragraph inline, add a bullet to an existing list in the right position, add one short paragraph or bullet at the end of a relevant section, and only as a last resort add a section at the end of `core-behavior.instructions.md`.

Order the edits: plan all of them across all memory and instruction files in one pass, group by target file, order bottom-up within each file so line numbers hold, then apply each file's edits in a single `multi_replace_string_in_file` call.

## Delete

Delete every specified memory file with `memory delete /memories/<scope>/<name>.md`. The file has served its purpose: absorbed facts now live in the instruction files and the rest were not worth preserving. When an edit in the previous step failed, keep the file and report the failure instead.

## Verify

Re-read each modified instruction file and confirm the facts are present and accurately expressed. Prune any fact now stated twice in the same file, keeping the better-placed instance. Check the voice: it should read as if the knowledge was always there, with no transitions and no memory dumps.

## Rules

- Prefer modifying existing content over adding new, and a new bullet over a new list.
- Never dump memories verbatim. Rephrase into the target file's voice.
- Skip a memory that is already fully covered.
- No editorial markers such as "Added from memory:" or "Note:".
