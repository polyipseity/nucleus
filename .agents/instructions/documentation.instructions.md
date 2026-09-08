---
description: "Use when adding or editing infrastructure code or data files: Nix, PowerShell, DSC YAML, shell scripts, JSON, YAML, MANUAL.md. Covers documentation standards, citation quality, WHY-not-WHAT commenting, and deterministic JSON generation."
name: "Documentation Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.json, src/**/*.jsonc, src/**/*.yaml, src/**/*.yml, src/hosts/Windows/**/*.yml, src/hosts/**/MANUAL.md, scripts/**, src/scripts/**"
alwaysApply: true
---

# Documentation standards

Document **WHY, not WHAT** — rationale, security, tradeoffs — not code restatements. Rationale: `# WHY: <reason>`. No backwards compat. When a setting cannot be auto-validated, add an inline source citation (`citation-quality.reference.md`).

## Nix files (`src/**/*.nix`)

Inline `#` comments. **File header**: `# <relative-path> — <purpose>`. **`let` bindings**: comment what each computes and why. **Activation entries**: banner comment (separator + name + purpose + algorithm); see `platforms/macOS/modules/default.nix`. **`mkOption`**: `description` mandatory — explain control and value effects, not the type. **Non-obvious code** (`builtins.*`, `lib.*`): comment the purpose. **WHY**: rationale, security, tradeoffs behind settings.

## PowerShell files (`src/**/*.ps1`)

Comment-based help on every function and entry-point. **Script-level**: `<# .SYNOPSIS … .DESCRIPTION … .PARAMETER … .EXAMPLE … #>` before `param(…)`. **Function-level**: same block, one `.PARAMETER` per param, add `.OUTPUTS` when returning a value. **Inline**: non-obvious logic, exit codes, idioms. Document WHY behind security/error-handling patterns.

## WinGet DSC YAML (`src/hosts/Windows/**/*.yml`)

`directives.description:` on every resource. State reason and practical effect, not the resource type. Non-obvious values: explain what enabling/disabling changes. `dependsOn:`: note the ordering reason.

## Shell scripts (`scripts/**`, `src/scripts/**`)

**File header** (after shebang): what, args, env vars, exit conditions. **Functions**: what, args, outputs, preconditions (see `scripts/bootstrap.sh`). **Logic**: `#` for non-obvious `case` branches, conditionals, env reads. WHY for tool/flag choices.

## Host MANUAL.md (`src/hosts/**/MANUAL.md`)

Ongoing operations only. Minimal formatting: title + bullets + backtick names. `command shortcuts` + `nucleus commands` sections. Group permissions by category. Remove when automatable.

## UI label naming

Sentence case for all user-facing labels across all hosts (macOS `NSMenuItem`, NixOS Nautilus/Dolphin `Name=`, Windows Registry `valueData`). Exception: system-internal identifiers, filenames differing from display names, AppleScript source.

## Citation quality

Developer docs over user help. Apple URLs need `en-us`. Never cite deprecated APIs as current. Full rules: `citation-quality.reference.md`.

## Deterministic JSON

Byte-stable across runs. Keys sorted case-sensitively by char code (`ConvertTo-Json` does NOT sort). Arrays sorted when sets/allow-lists. Single trailing newline, 2-space indent, compact empty objects/arrays. Use `toSortedJSON` (Nix) or `ConvertTo-SortedJson` (PowerShell). No insertion-order drift. In-memory JSON never persisted is exempt.

## Markdown and agent customization

Short, scannable, repo-specific. Follow `.markdownlint.jsonc` (root) and `.agents/.markdownlint.jsonc` (`.agents/**`). `MD013`/`MD033`/`MD051` disabled; `MD036` disabled under `.agents/**`. Valid YAML frontmatter in `.instructions.md`/`.prompt.md`. `commit-staged.prompt.md` tripled across three locations; body must match. No `.github/copilot-instructions.md`.
