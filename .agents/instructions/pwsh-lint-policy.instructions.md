---
description: "Use when authoring or editing PowerShell files: authoring conventions (file naming, here-strings, parameter passing), PSScriptAnalyzer lint results, suppression rules, per-rule fix strategies, and how to document new rule policies."
name: "PowerShell Lint Policy"
applyTo: "**/*.ps1, scripts/*-PSScriptAnalyzerSettings.psd1"
---

# PowerShell lint rule fixing policy

## PowerShell conventions

### File naming

Standalone entry points: PascalCase `Verb-Noun` (e.g. `Get-SystemInventory.ps1`). The `scripts/` directory keeps paired shell basenames (`.sh` + `.ps1` aligned). Modules under `src/platforms/Windows/modules/` should export a single `Verb-Noun` function per file; rename the module and update `src/hosts/Windows/apply.ps1` dot-sourcing paths in the same change. Collection-operating functions use collection-indicating singular nouns: see `## PSUseSingularNouns` below.

### Here-string extraction

Extract inline here-strings to `modules/scripts/<name>.ps1`. Read with `Get-Content -Raw (Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\<name>.ps1")`. Token replacement for double-quote here-strings: `-replace '__TOKEN__', $value`. Single-quote here-strings need no replacement.

### Explicit parameter passing

Behavioral parameters (`Enabled`, `Users`) must be `[Parameter(Mandatory)]`. Never auto-derive paths from `$PSScriptRoot`. Functions touching user profiles need explicit `-Username` or `-Users`. No deprecated parameters — remove entirely. Show all mandatory parameters in `.SYNOPSIS` and `.EXAMPLE`.

## Suppression rules

1. **Redirect first.** Use `> $null` to discard output — fastest, cleanest, no annotation needed.
2. **`$null =` or `[void]` next.** When redirect cannot work (not pipeline output), use `$null = <expr>` or `[void]<expr>`. Both require `# check-suppress:suppression_doc:` annotation.
3. **`| Out-Null` is banned.** Replace with `> $null` or `$null =` with annotation.
4. **No file-scope `[SuppressMessageAttribute]`.** Too coarse. Use `$null =`/`[void]` with annotation. The attribute is allowed only when no code path can be annotated (e.g. function-name wrappers). Place it inside the function body before `param()`; specific rule IDs only.
5. **Every suppression needs an annotation.** `$null =`/`[void]` → `# check-suppress:suppression_doc: <reason>`; `[SuppressMessageAttribute]` → `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>`.
6. **No catch-all suppressions.** Specific rule IDs only.

## Suppression methods

| Method | When | Annotation | Speed |
| --- | --- | --- | --- |
| `> $null` | Pipeline output discard | None (not a suppression) | Fastest |
| `$null = <expr>` | Non-pipeline output, .NET method returns | `# check-suppress:suppression_doc:` | Fast |
| `[void]<expr>` | Method calls needing value suppression | `# check-suppress:suppression_doc:` | Slightly slower than `$null =` |
| `2>$null` | stderr-only suppression | `# check-suppress:suppression_doc:` | — |
| `*> $null` | All-stream suppression | `# check-suppress:suppression_doc:` | — |
| `| Out-Null` | **Banned** | — | Slowest (pipeline overhead) |

## Rule-specific fix strategies

### `PSUseUsingScopeModifierInNewRunspaces` with `$using:VAR.Count`

**Trigger:** Member access on `$using:` in `Start-Job`/`Start-ThreadJob` (e.g. `$using:PS1_FILES.Count`).

**Root cause:** AST places `$using:` under `MemberExpressionAst`, not `UsingExpressionAst`. Rule checks only immediate parent. **Upstream:** [#1504](https://github.com/PowerShell/PSScriptAnalyzer/issues/1504) (open since 2020), [#2005](https://github.com/PowerShell/PSScriptAnalyzer/pull/2005) (tests only).

**Fix:** Assign `$using:` to a local, use member access on the local:

```powershell
# BAD — triggers false positive:
if ($using:PS1_FILES.Count -gt 0) { ... $using:PS1_FILES ... }
# GOOD:
$_ps1Files = $using:PS1_FILES
if ($_ps1Files.Count -gt 0) { ... $_ps1Files ... }
```

### `PSUseApprovedVerbs`

**Trigger:** Unapproved verb in function name (e.g. `Ensure-Tool`).

**Fix:** Rename to an [approved verb](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands). Lowercase helpers (`say`, `warn`, `error`) must also be renamed to Verb-Noun format.

**Command-name wrappers** (`python`, `bun`, `cargo`): Keep lowercase name. Non-hyphenated names don't trigger this rule, but `node` triggers `PSAvoidOverwritingBuiltInCmdlets`. Add suppression inside the function body before `param()`:

```powershell
function node {
  # check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets -- intentional: shadows native node; warns to use bun equivalents
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
  param()
  ...
}
```

The comment syntax `# SuppressMessageAttribute(...)` does NOT work — PSSA reads only `AttributeAst` from param blocks. The attribute MUST go inside the function body before `param()`, with `# check-suppress:` on the same line or immediately above.

**`Add-ShellAlias`**: Creates aliases via `New-Item -Path Function:` — no `FunctionDefinitionAst` produced, so no verb check.

**`nucleus-*` wrappers**: Trigger because `nucleus` is not approved. Add the attribute inside the function body before `param()`. Prefer `Add-ShellAlias` when the exact name is not required.

**`Sort` is not an approved verb** (`Sort-Object` is a legacy exception, and `Get-Verb Sort` returns nothing): rename such functions, e.g. `Sort-JsonObject` → `ConvertTo-SortedJsonObject`.

### `PSUseSingularNouns`

**Trigger:** Plural noun in function name (e.g. `Get-VmRunningNames`).

Renaming alone is not enough — verify whether the function operates on a collection before picking the right noun.

### Anti-pattern: naive de-pluralization

Dropping the trailing `s` is **wrong** when the function handles multiple items:

| Wrong (naive) | Right (collection-indicating singular) | Why |
| --- | --- | --- |
| `Sync-Symlinks` → `Sync-Symlink` | `Sync-Symlinks` → `Sync-SymlinkManifest` | Manifest-driven multi-symlink convergence |
| `Get-ServiceLogDirs` → `Get-ServiceLogDir` | `Get-ServiceLogDirs` → `Get-ServiceLogDirList` | Returns an array of log directory paths |
| `Get-WallpaperEncryptedBlobs` → `Get-WallpaperEncryptedBlob` | `Get-WallpaperEncryptedBlobs` → `Get-WallpaperEncryptedBlobList` | Returns `string[]` of blob names |

### Naming decision tree

1. Plural flagged? → step 2. Not flagged? → still check step 3.
2. Multiple homogeneous items? → collection-indicating singular. Otherwise → bare singular.
3. One logical config surface? → bare singular or `*Config`/`*Service`.
4. When in doubt, prefer collection suffix.

### `Sync-*` suffix selection guide

| Suffix | Use when | Examples |
| --- | --- | --- |
| `*Manifest` | Manifest JSON drives item list | `Sync-SymlinkManifest`, `Sync-VSCodeExtensionManifest` |
| `*Catalog` | Registry/domain arrays | `Sync-DevRepoCatalog`, `Sync-CloudDriveCatalog` |
| `Inventory` | Materialized asset set across users/files | `Sync-WallpaperInventory` |
| `*Config` | Single app/config tree | `Sync-AgentsConfig`, `Sync-CursorConfig` |
| `*Service` | Single Windows service | `Sync-CaddyService`, `Sync-LiteLLMService` |

**Fix:** Single item → bare singular. Multiple items → collection-indicating singular.

**Allowed collection nouns:** List, Set, Collection, Array, Group, Batch, Bundle, Cluster, Map, Dictionary, Hash, Hashtable, Index, Registry, Catalog, Table, Queue, Stack, Vector, Matrix, Range, Buffer, Pool, Cache, Heap, Ring, Tree, Graph, Stream, Sequence, Series, Enum, Inventory, Manifest, Record, Store, Archive, Suite, Toolkit, Library, Report, Aggregate, Compilation, Overview, Summary.

**Never suppress. Rename the function.**

**Edge cases:** Words ending in 's' that are inherently singular (Status, alias, process, bus, focus, virus, analysis, basis, crisis, thesis) are not violations.

### `PSUseShouldProcessForStateChangingFunctions`

**Trigger:** A function whose verb is `New`, `Set`, or `Remove` — the only verbs this rule checks; `Initialize-`, `Add-`, and `Enable-` are not flagged (verified with a probe file).

**Fix:** Add `[CmdletBinding(SupportsShouldProcess)]` and gate the mutation with `$PSCmdlet.ShouldProcess(<target>, <action>)`, following `Set-ManagedSymlinkDeleteProtection.ps1`, `Remove-ManagedSecret.ps1`, `Set-VSCodeWorkspaceTrust.ps1`, and `Set-PiProjectTrust.ps1`. Callers that pass no `-WhatIf` keep the current behaviour, and the paired `PSUseSupportsShouldProcess`/`PSShouldProcess` rules stay satisfied because the gate is actually called. Test fixtures that create files take the same treatment.

**Not the same rule as `PSShouldProcess`.** `scripts/check-PSScriptAnalyzerSettings.psd1` excludes `PSShouldProcess`, which is a separate rule of the same family; excluding one does not silence the other.

### `PSUseOutputTypeCorrectly`

**Trigger:** A function returns a type that is not declared in an `OutputType` attribute.

**Fix:** Declare what the function actually returns (`[OutputType([string])]`, `[OutputType([System.Collections.Specialized.OrderedDictionary])]`). A helper that returns several shapes — including `$null` and a passthrough scalar — declares the polymorphic contract once: `[OutputType([object])]`.

### `PSReviewUnusedParameter`

**Trigger:** A parameter that the rule cannot see being read.

**Root cause:** The rule does not follow nested function definitions, so a parameter read only from a helper defined inside the same function (or, symmetrically, a script parameter read only inside a function) is reported as unused even though it is used.

**Fix:** Make the read visible in the consuming scope. Bind the value where it is used (`$effectiveUsername = $Username`, then pass the local to the helpers), or give the callee an explicit parameter and pass it at the call site. Removing the parameter is valid only when nothing reads it. `$null = <param>` plus `# check-suppress:suppression_doc: <reason>` is the last resort.

### `PSAvoidUsingPositionalParameters`

**Trigger:** A command call with positional arguments (e.g. `Join-Path $PSScriptRoot 'x.ps1'`).

**Fix:** Name the parameters (`Join-Path -Path ... -ChildPath ...`).

### `PSUseDeclaredVarsMoreThanAssignments`

**Trigger:** A variable that is assigned but never read.

**Fix:** Read it in the assertion or computation that needs it, or delete it; use `> $null` when a command's output is deliberately discarded.

## Reference table

| Rule ID | Trigger | Fix |
| --- | --- | --- |
| `PSUseUsingScopeModifierInNewRunspaces` | `$using:VAR.Count` member access | Assign to local, use `.Count` on local |
| `PSUseApprovedVerbs` | Unapproved verb | Rename to approved verb; lowercase helpers → Verb-Noun; command wrappers → inline suppression |
| `PSUseSingularNouns` | Plural noun | Bare singular (single-return) or collection-indicating singular (multi-return) |
| `PSUseDeclaredVarsMoreThanAssignments` | `$null = <cmd>` or `[void]<expr>` | `> $null` redirect preferred, else annotate |
| `PSPossibleIncorrectComparisonWithNull` | `$null = <cmd>` | `> $null` redirect preferred, else annotate |
| `PSReviewUnusedParameter` / `PSAvoidUsingUnusedParameters` | Parameter read only from a nested function definition | Bind locally or pass explicitly; remove when nothing reads it; annotate `$null =` as a last resort |
| `PSUseShouldProcessForStateChangingFunctions` | `New`/`Set`/`Remove` verb | `[CmdletBinding(SupportsShouldProcess)]` + `$PSCmdlet.ShouldProcess(...)`; distinct from the excluded `PSShouldProcess` |
| `PSUseOutputTypeCorrectly` | Returned type not declared | `[OutputType([<type>])]`; `[OutputType([object])]` for a polymorphic helper |
| `PSAvoidUsingPositionalParameters` | Positional command arguments | Name the parameters |

## Adding a new rule policy

Create a `## <RuleName>` section (trigger, root cause, fix with code, suppression policy, upstream link). Add a row to the reference table. Verify against actual repo code.

## Annotation reference

| Format | Class | Used for |
| --- | --- | --- |
| `# check-suppress:SuppressMessageAttribute: <RuleName> -- <reason>` | A/C | `[SuppressMessageAttribute]`, comment-only PSSA suppression |
| `# check-suppress:suppression_doc: <reason>` | B | `$null =`, `[void]`, `2>$null`, `-ErrorAction SilentlyContinue`, `catch {}`, `|| true` |

Grep-able: `grep 'check-suppress:' **/*.ps1`. Enforced by `check.ps1` step 12.
