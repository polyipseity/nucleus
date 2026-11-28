---
description: "Use when editing infrastructure code, data files, or MANUAL.md."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.json, src/**/*.jsonc, src/**/*.yaml, src/**/*.yml, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
alwaysApply: true
---

# Documentation standards

Document WHY, not WHAT: rationale, security, tradeoffs, never a restatement of code. Rationale goes in `# WHY: <reason>`. No backwards compatibility. Cite a source inline when a setting cannot be auto-validated; source rules are in `src/users/default/agents/skills/nucleus-citation-reference/references/citation-quality.md`.

Before editing text, check for a test that pins lines: `grep -rl '<file>' tests/`, then look for a line-number allowlist. Edit only below the pin, because a line comparison against HEAD fails on any shift.

## Comment bar

A comment earns its place only when its absence could make a reader do the wrong thing: break a security constraint, undo a deliberate deviation, or trip over an apparent bug. Delete wrong comments rather than correcting them; correction implies the comment deserved to exist and hands re-verification to future readers. Delete comments whose subject a change deletes, and delete docs or instructions that disagree with code. Never write a confident claim nobody verified against the file.

Delete comments needing reworded every code change. Keep a truthful comment marking a genuine open gap. A shebang is not a comment: never move or delete one, even in a comment-only pass. Put comments on their own lines so a diff can distinguish them from code changes.

Text mirroring code does not list file paths, option names, package names, commands, or fields the code already states. Name the source of truth instead.

## Prose style

No em dash in repo-owned prose or comments. Use a comma, colon, or two sentences. Avoid additionally, crucial, pivotal, robust, seamless, comprehensive, delve, showcase, leverage, in order to, and it is important to note.

## Per file type

Nix: `# <relative-path>: <purpose>` header, `let`-binding comments where the why matters, a banner on activation entries, mandatory `mkOption description` explaining control and value effects rather than type, and a comment on non-obvious `builtins.*` / `lib.*` use.

PowerShell: comment-based help on every function and entry point. Script level `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` before `param(…)`; function level the same with one `.PARAMETER` per parameter and `.OUTPUTS` when returning a value. Document why behind security and error handling.

WinGet DSC YAML: `directives.description:` on every resource, stating reason and practical effect, not resource type. Explain non-obvious values and `dependsOn:` ordering.

Shell: header after the shebang covering purpose, args, env vars, and exit conditions. Per function: what, args, outputs, preconditions (`scripts/bootstrap.sh`). `#` for non-obvious branches, conditionals, env reads, and tool or flag choices.

`src/hosts/**/MANUAL.md`: ongoing operations only, never migration runbooks. Title, bullets, backticked names, `command shortcuts` and `nucleus commands` sections, permissions grouped by category. Delete a step once automatable.

## UI labels and citations

Sentence case for every user-facing label on every host (macOS `NSMenuItem`, NixOS Nautilus/Dolphin `Name=`, Windows Registry `valueData`). Exceptions: system-internal identifiers, filenames differing from the display name, and AppleScript source.

Developer docs over user help; Apple URLs include `en-us`; never cite a deprecated API as current. Full rules: `src/users/default/agents/skills/nucleus-citation-reference/references/citation-quality.md`.

## Deterministic JSON

Byte-stable across runs. Sort keys case-sensitively by char code (`ConvertTo-Json` does not sort); sort arrays that are sets or allow-lists. One trailing newline, 2-space indent, compact empty objects and arrays. Use `toSortedJSON` (Nix) or `ConvertTo-SortedJson` (PowerShell). In-memory JSON never persisted is exempt.

## Markdown and agent files

Keep docs short, scannable, repo-specific. `.markdownlint.jsonc` at root and `.agents/.markdownlint.jsonc` under `.agents/**`; `MD013`, `MD033`, `MD051` are off, `MD036` off under `.agents/**`. `.instructions.md` and `.prompt.md` need valid YAML frontmatter. `commit-staged.prompt.md` exists in both `.agents/prompts/` and `src/users/default/agents/prompts/`, and `tests/scripts/check-steps/agents-prompt-parity-tests.sh` compares bodies, so edit both. Never add `.github/copilot-instructions.md`.
