---
description: "Use when adding or editing infrastructure code or data files: Nix, PowerShell, DSC YAML, shell scripts, JSON, YAML, MANUAL.md. Covers documentation standards, citation quality, WHY-not-WHAT commenting, and deterministic JSON generation."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.json, src/**/*.jsonc, src/**/*.yaml, src/**/*.yml, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
alwaysApply: true
---

# Documentation standards

Document WHY, not WHAT: rationale, security, tradeoffs, never a restatement of the code. Rationale goes in `# WHY: <reason>`. No backwards compat. Cite a source inline when a setting cannot be auto-validated (`citation-quality.reference.md`).

## Before editing text

Before editing text in a file, check whether a test pins lines in it: `grep -rl '<file>' tests/`, then look for a line-number allowlist. Edit only below the pinned line, because a test that compares line N to HEAD fails on any shift, so a comment cut above the pin breaks the suite.

## Comment bar

A comment earns its place only when its absence could make a reader do the wrong thing: change a security constraint, undo a deliberate deviation, or be surprised by an apparent bug. Everything else goes.

Wrong comments are deleted, not corrected. Correction preserves the assumption that the comment deserved to exist and hands a re-verification obligation to every future reader; deletion cannot rot. A comment whose subject a change deletes goes with the subject. Same for docs and instruction files: when the text and the code disagree, delete the text.

The characteristic failure is a confident claim about code nobody verified. If a comment cannot be checked against the file in front of you, it does not get written.

Two exceptions to deletion. A comment that has to be reworded every time the code under it changes has already cost more upkeep than it returns, so cut it. A truthful comment marking a genuine open gap stays: it is what stops unexecuted work reading as finished, and rewording it as the gap narrows is not upkeep.

A shebang is not a comment. Never move or delete one, not even in a comment-only pass, because a line-based "only comments changed" check cannot see it. Put a comment on its own line rather than at the end of a code line, since a diff cannot tell a reworded comment from a code change.

## Text that mirrors code

A doc or comment does not list file paths, option names, package names, command names, or field names that the code already states. Name the source of truth instead. A list is a copy that goes stale the first time the code moves.

## Prose style

No em dash in repo-owned prose or comments. Use a comma, a colon, or two sentences. Same for the filler words additionally, crucial, pivotal, robust, seamless, comprehensive, delve, showcase, leverage, in order to, it is important to note.

## Per file type

Nix: `# <relative-path>: <purpose>` header, comments on `let` bindings that need the why, a banner comment on each activation entry (see `platforms/macOS/modules/default.nix`), a mandatory `mkOption` `description` that explains control and value effects rather than the type, and a comment on non-obvious `builtins.*` / `lib.*` use.

PowerShell: comment-based help on every function and entry point. Script level: `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` before `param(…)`. Function level: the same block, one `.PARAMETER` per parameter, `.OUTPUTS` when returning a value. Document the why behind security and error-handling patterns.

WinGet DSC YAML: `directives.description:` on every resource, stating reason and practical effect rather than the resource type. Explain what a non-obvious value changes when enabled or disabled, and the ordering reason for `dependsOn:`.

Shell: header after the shebang covering what the script does, its args, env vars, and exit conditions. Per function: what, args, outputs, preconditions (see `scripts/bootstrap.sh`). `#` for non-obvious `case` branches, conditionals, and env reads, and a why for tool or flag choices.

`src/hosts/**/MANUAL.md`: ongoing operations only, so a recurring post-apply step that cannot be automated. Never a migration runbook. Title plus bullets plus backticked names, with `command shortcuts` and `nucleus commands` sections and permissions grouped by category. Delete a step once it is automatable.

## UI label naming

Sentence case for every user-facing label on every host (macOS `NSMenuItem`, NixOS Nautilus/Dolphin `Name=`, Windows Registry `valueData`). Exceptions: system-internal identifiers, filenames that differ from the display name, and AppleScript source.

## Citation quality

Developer docs over user help. Apple URLs need `en-us`. Never cite a deprecated API as current. Rules: `citation-quality.reference.md`.

## Deterministic JSON

Byte-stable across runs. Keys sorted case-sensitively by char code (`ConvertTo-Json` does not sort). Arrays sorted when they are sets or allow-lists. One trailing newline, 2-space indent, compact empty objects and arrays. Use `toSortedJSON` (Nix) or `ConvertTo-SortedJson` (PowerShell). In-memory JSON that is never persisted is exempt.

## Markdown and agent customization

Short, scannable, repo-specific. `.markdownlint.jsonc` at the root and `.agents/.markdownlint.jsonc` under `.agents/**`; `MD013`, `MD033`, and `MD051` are off, `MD036` is off under `.agents/**`. `.instructions.md` and `.prompt.md` need valid YAML frontmatter. `commit-staged.prompt.md` exists in both `.agents/prompts/` and `src/users/default/agents/prompts/` and `tests/scripts/check-steps/agents-prompt-parity-tests.sh` compares the bodies, so edit them together. Never add `.github/copilot-instructions.md`.
