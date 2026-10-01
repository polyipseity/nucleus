---
description: "Use when authoring or editing PowerShell files: authoring conventions (file naming, here-strings, parameter passing), PSScriptAnalyzer lint results, suppression rules, per-rule fix strategies, and how to document new rule policies."
name: "PowerShell Lint Policy"
applyTo: "**/*.ps1, scripts/*-PSScriptAnalyzerSettings.psd1"
---

# PowerShell lint rule fixing policy

## PowerShell conventions

### File naming

Standalone entry points: PascalCase `Verb-Noun` (`Get-SystemInventory.ps1`). `scripts/` keeps paired basenames (`.sh` + `.ps1` aligned). A module in `src/platforms/Windows/modules/` exports one `Verb-Noun` function; rename it and update the `src/hosts/Windows/apply.ps1` dot-source in the same change. Collection-operating functions take a collection-indicating singular noun (see `PSUseSingularNouns`).

### Here-string extraction

Extract inline here-strings to `modules/scripts/<name>.ps1`, read with `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\<name>.ps1")`. Replace `__TOKEN__` in double-quoted here-strings with `-replace '__TOKEN__', $value`; single-quoted here-strings need no replacement.

### Explicit parameter passing

Behavioral parameters (`Enabled`, `Users`) are `[Parameter(Mandatory)]`. Never auto-derive paths from `$PSScriptRoot`. Functions touching user profiles need explicit `-Username` or `-Users`. Deprecated parameters are removed, not kept working. Document every mandatory parameter in `.SYNOPSIS` and `.EXAMPLE`.

## Suppression rules

1. `> $null` discards pipeline output. Fastest, no annotation.
2. `$null = <expr>` or `[void]<expr>` when a redirect cannot work (non-pipeline output, .NET returns). Both need `# check-suppress:suppression_doc: <reason>`.
3. `| Out-Null` is banned; use `> $null` or an annotated `$null =`.
4. No file-scope `[SuppressMessageAttribute]`. It is allowed only where no code path can carry an annotation (function-name wrappers), inside the body before `param()`, with specific rule IDs only.
5. No catch-all suppressions.
6. `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>` is the annotation for the attribute.

| Method | When | Annotation |
| --- | --- | --- |
| `> $null` | Pipeline output | none |
| `$null = <expr>` | Non-pipeline output, .NET returns | `suppression_doc` |
| `[void]<expr>` | Value-suppressed method call | `suppression_doc` |
| `2>$null` | stderr only | `suppression_doc` |
| `*> $null` | All streams | `suppression_doc` |

## Rule-specific fix strategies

### `PSUseUsingScopeModifierInNewRunspaces` with `$using:VAR.Count`

**Trigger:** Member access on `$using:` in `Start-Job`/`Start-ThreadJob`, e.g. `$using:PS1_FILES.Count`.

**Root cause:** the AST places `$using:` under `MemberExpressionAst`, not `UsingExpressionAst`, and the rule only checks the immediate parent. Upstream: [#1504](https://github.com/PowerShell/PSScriptAnalyzer/issues/1504) (open since 2020), [#2005](https://github.com/PowerShell/PSScriptAnalyzer/pull/2005) (tests only).

**Fix:** bind to a local, then take member access on the local.

```powershell
# BAD: false positive
if ($using:PS1_FILES.Count -gt 0) { ... $using:PS1_FILES ... }
# GOOD
$_ps1Files = $using:PS1_FILES
if ($_ps1Files.Count -gt 0) { ... $_ps1Files ... }
```

### `PSUseApprovedVerbs`

**Trigger:** unapproved verb in a function name, e.g. `Ensure-Tool`. `Sort` is unapproved (`Sort-Object` is a legacy exception).

**Fix:** rename to an [approved verb](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands). Lowercase helpers (`say`, `warn`, `error`) become Verb-Noun too.

Command-name wrappers (`python`, `bun`, `cargo`) keep their lowercase name: non-hyphenated names skip this rule, but `node` trips `PSAvoidOverwritingBuiltInCmdlets`. Suppress it with the attribute inside the body before `param()`. `Add-ShellAlias` needs nothing, because `New-Item -Path Function:` produces no `FunctionDefinitionAst`. `nucleus-*` wrappers trip the rule because `nucleus` is unapproved; prefer `Add-ShellAlias` unless the exact name matters. A `# SuppressMessageAttribute(...)` comment does not work, since PSSA reads only an `AttributeAst`.

### `PSUseSingularNouns`

**Trigger:** plural noun in a function name, e.g. `Get-VmRunningNames`.

**Fix:** decide by what the function returns. One item: bare singular (`Sync-Symlink`). Multiple items: collection-indicating singular (`Sync-SymlinkManifest`, `Get-ServiceLogDirList`). One logical config surface: bare singular, `*Config`, or `*Service`. Dropping the trailing `s` (`Get-VmRunningNames` → `Get-VmRunningName`) is wrong when the function handles a list.

Suffix by driver: `*Manifest` for a manifest JSON that drives the item list, `*Catalog` for registry/domain arrays, `Inventory` for a materialized asset set, `*Config` for one app/config tree, `*Service` for one Windows service.

Allowed collection nouns: List, Set, Collection, Array, Group, Batch, Bundle, Cluster, Map, Dictionary, Hash, Hashtable, Index, Registry, Catalog, Table, Queue, Stack, Vector, Matrix, Range, Buffer, Pool, Cache, Heap, Ring, Tree, Graph, Stream, Sequence, Series, Enum, Inventory, Manifest, Record, Store, Archive, Suite, Toolkit, Library, Report, Aggregate, Compilation, Overview, Summary.

Never suppress; rename. Words ending in `s` that are inherently singular (Status, alias, process, bus, focus, virus, analysis, basis, crisis, thesis) are not violations.

### `PSUseShouldProcessForStateChangingFunctions`

**Trigger:** a function whose verb is `New`, `Set`, or `Remove`. Those three are the only verbs checked; `Initialize-`, `Add-`, and `Enable-` are not flagged (verified with a probe file).

**Fix:** add `[CmdletBinding(SupportsShouldProcess)]` and gate the mutation on `$PSCmdlet.ShouldProcess(<target>, <action>)`, following `Set-ManagedSymlinkDeleteProtection.ps1`, `Remove-ManagedSecret.ps1`, `Set-VSCodeWorkspaceTrust.ps1`, `Set-PiProjectTrust.ps1`. Callers that pass no `-WhatIf` keep current behavior, and `PSUseSupportsShouldProcess`/`PSShouldProcess` stay satisfied because the gate is actually called. Test fixtures that create files take the same treatment.

`PSShouldProcess` is excluded in `scripts/check-PSScriptAnalyzerSettings.psd1` and that does not silence this rule.

### `PSReviewUnusedParameter`

**Trigger:** a parameter the rule cannot see being read.

**Root cause:** the rule does not follow nested function definitions, so a parameter read only from a helper defined inside the same function (or a script parameter read only inside a function) reads as unused.

**Fix:** make the read visible where it is used: bind the value to a local (`$effectiveUsername = $Username`) and pass the local, or give the callee its own parameter. Remove the parameter only when nothing reads it. `$null = <param>` plus `# check-suppress:suppression_doc: <reason>` is the last resort.

## Reference table

| Rule ID | Trigger | Fix |
| --- | --- | --- |
| `PSUseOutputTypeCorrectly` | Returned type not declared | `[OutputType([<type>])]`; `[OutputType([object])]` for a helper that also returns `$null` or a passthrough scalar |
| `PSAvoidUsingPositionalParameters` | Positional command arguments | Name them (`Join-Path -Path ... -ChildPath ...`) |
| `PSUseDeclaredVarsMoreThanAssignments` | Variable assigned but never read | Read it where it is needed, or delete it; `> $null` when the output is deliberately discarded |
| `PSPossibleIncorrectComparisonWithNull` | `$null = <cmd>` | `> $null` instead, else annotate |

## Adding a new rule policy

Add a `## <RuleName>` section holding trigger, root cause, fix, suppression policy, and the upstream link, plus a reference-table row. Verify it against real repo code.
