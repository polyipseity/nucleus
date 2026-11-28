---
description: "Use when authoring or editing PowerShell files and fixing PSScriptAnalyzer findings."
name: "PowerShell Lint Policy"
applyTo: "**/*.ps1, scripts/*-PSScriptAnalyzerSettings.psd1"
---

# PowerShell lint rule fixing policy

## Conventions

Standalone entry points use PascalCase `Verb-Noun` (`Get-SystemInventory.ps1`). `scripts/` keeps paired `.sh` and `.ps1` basenames. A module under `src/platforms/Windows/modules/` exports one `Verb-Noun` function; rename it and update the `src/hosts/Windows/apply.ps1` dot-source in the same change. Collection functions take a collection-indicating singular noun.

Extract inline here-strings to `modules/scripts/<name>.ps1` and read them with `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\<name>.ps1")`. Replace `__TOKEN__` in double-quoted here-strings with `-replace '__TOKEN__', $value`; single-quoted strings need no replacement.

Behavioral parameters (`Enabled`, `Users`) are `[Parameter(Mandatory)]`. Never auto-derive paths from `$PSScriptRoot`. Functions touching profiles need explicit `-Username` or `-Users`. Remove deprecated parameters rather than keeping them working. Document every mandatory parameter in `.SYNOPSIS` and `.EXAMPLE`.

## Suppression rules

`> $null` discards pipeline output with no annotation. `$null = <expr>` and `[void]<expr>` need `# check-suppress:suppression_doc: <reason>` when a redirect cannot work. `| Out-Null` is banned. No file-scope `[SuppressMessageAttribute]`: it is allowed only where no code path can carry an annotation (function-name wrappers), inside the body before `param()`, with specific rule IDs. No catch-all suppressions; annotate attributes with `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>`.

| Method | When | Annotation |
| --- | --- | --- |
| `> $null` | Pipeline output | none |
| `$null = <expr>` | Non-pipeline output, .NET returns | `suppression_doc` |
| `[void]<expr>` | Value-suppressed method call | `suppression_doc` |
| `2>$null` | stderr only | `suppression_doc` |
| `*> $null` | All streams | `suppression_doc` |

## Rule fixes

Triggers, root causes, fixes, and the quick reference table live in `src/users/default/agents/skills/nucleus-policy-reference/references/pssa-rules.md`. Key constraints: PSSA 1.25.0 flags only eight state-changing verbs (`New`, `Set`, `Remove`, `Reset`, `Stop`, `Restart`, `Start`, `Update`), fixed with `[CmdletBinding(SupportsShouldProcess)]` and `$PSCmdlet.ShouldProcess()`; `PSUseSingularNouns` is never suppressed; remove `[ValidateSet]` from a positional `Action` that also accepts `--list-*` flags and normalize with `Resolve-NucleusArgument` plus `Assert-NucleusCliAction`.

## Adding a new rule policy

Add a `## <RuleName>` section with trigger, root cause, fix, suppression policy, and upstream link, plus a reference-table row in the skill file. Verify against real repo code.
