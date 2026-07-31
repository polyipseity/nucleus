---
description: "Use when handling PSScriptAnalyzer lint results in PowerShell files. Covers suppression rules, per-rule fix strategies, and how to document new rule policies."
name: "PowerShell Lint Policy"
applyTo: "**/*.ps1, scripts/PSScriptAnalyzerSettings.*.psd1"
---

# PowerShell lint rule fixing policy

## Suppression rules

1. **Prefer redirecting over suppressing.** Use `> $null` to discard output — it is the fastest and cleanest method and is NOT considered a suppression (no annotation required). Reach for redirect first before any suppression technique.
2. **Prefer `$null =` or `[void]` over `[SuppressMessageAttribute]` attribute.** When redirect cannot work (e.g., the value is not pipeline output), use `$null = <expr>` or (for method calls) `[void]<expr>`. These ARE considered suppressions and require `# check-suppress:SuppressMessageAttribute:` annotation.
3. **`| Out-Null` is banned.** It is substantially slower than alternatives due to pipeline overhead. Replace all instances with `> $null` (preferred) or `$null =` with annotation.
4. **Avoid file-scope `[SuppressMessageAttribute('RuleId', '')]` attribute.** Placed on a file-scope `param()` block it applies to the entire file (too coarse). Prefer `$null =` or `[void]` with `# check-suppress:SuppressMessageAttribute:` annotation. Use the attribute only when there is literally no code path to annotate — e.g. a function name that must keep its exact form (see `PSUseApprovedVerbs` command-name wrappers below). In that case place it INSIDE the function body immediately before `param()` — this scopes it to that single function only. When unavoidable, must minimize rules covered (list specific rule IDs, no wildcards).
5. **Every suppression needs an annotation.** `$null =`, `[void]`, and `[SuppressMessageAttribute]` attribute must have a `# check-suppress:SuppressMessageAttribute: <RuleId> — <reason>` comment on the same line or preceding line. File-level suppressions of any kind are prohibited.
6. **No catch-all suppressions.** Suppress specific rule IDs. No wildcards or blanket suppressions.

## Redirect alternative (`> $null`)

`> $null` is the preferred way to discard output. It is NOT a suppression and needs no annotation.

- **Performance:** `> $null` and `$null =` are fastest, `[void]` slightly slower, `| Out-Null` is much slower (pipeline overhead).
- **Syntax:** `Get-ChildItem > $null` (redirects stdout to null). Use `2>$null` for stderr-only suppression (see B-class section below).
- **Multi-stream:** `*> $null` redirects all streams to null.
- **`2>$null`** stays documented under B-class error suppression with `# check-suppress:suppression_doc:` annotation.

## `$null = <expr>` suppression

- **Trigger:** Assigning command output to `$null` to suppress it, e.g. `$null = New-Item -Path $dir -ItemType Directory -Force`.
- **When acceptable:** When the output must be discarded but `> $null` redirect cannot work (e.g., the value is not pipeline output, or the expression is a .NET method call with a return value).
- **Annotation format:** `$null = New-Item ...  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — $null = intentional suppression`
- **PSSA rules commonly triggered:** `PSUseDeclaredVarsMoreThanAssignments`, `PSPossibleIncorrectComparisonWithNull`

## `[void]<expr>` suppression

- **Trigger:** Casting an expression to `[void]` to suppress its return value, e.g. `[void]$object.SomeMethod()`.
- **When acceptable:** When the expression is a method call returning a value that must be suppressed.
- **Annotation format:** `[void]$object.SomeMethod()  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — reason`
- **Note:** `[void]` is slightly slower than `$null =` and `> $null`. Prefer `$null =` when both work.

## `| Out-Null` — banned

`| Out-Null` is BANNED. Do not use it in new code. Replace all existing instances.

- **Replacement patterns:**
  - `Command-WithOutput | Out-Null` → `Command-WithOutput > $null`
  - `$null = Command-WithOutput  # check-suppress:SuppressMessageAttribute: RuleId — reason` (when redirect cannot work)
- **Exception:** None. Every `| Out-Null` must be replaced.

## Rule-specific fix strategies

### `PSUseUsingScopeModifierInNewRunspaces` with `$using:VAR.Count`

**Trigger:** Accessing a property/member on a `$using:` variable inside a `Start-Job` / `Start-ThreadJob` script block, e.g. `$using:PS1_FILES.Count`.

**Root cause:** The AST for `$using:PS1_FILES.Count` places the `VariableExpressionAst` (`$using:PS1_FILES`) under a `MemberExpressionAst`, **not** a `UsingExpressionAst`. The rule's `IsNonUsingNonSpecialVariableExpressionAst` predicate only checks the immediate parent, so it misses the `$using:` scope modifier in the ancestor chain and falsely flags it as undeclared.

**Upstream status:**

- [Issue #1504](https://github.com/PowerShell/PSScriptAnalyzer/issues/1504): General false-positive tracking (open since 2020)
- [PR #2005](https://github.com/PowerShell/PSScriptAnalyzer/pull/2005): Draft PR adding tests for the issue but no fix (May 2024)
- No dedicated bug report for member-access false positive exists; the scope-ancestor check has never been addressed upstream

**Fix:** Assign the `$using:` variable to a local first, then use `.Count` (or other member access) on the local:

```powershell
# BAD — triggers false positive:
if ($using:PS1_FILES.Count -gt 0) { ... $using:PS1_FILES ... }

# GOOD — no warning:
$_ps1Files = $using:PS1_FILES
if ($_ps1Files.Count -gt 0) { ... $_ps1Files ... }
```

### `PSUseApprovedVerbs` — always use approved verbs

**Trigger:** Function or cmdlet name using an unapproved verb, e.g. `Ensure-Tool`.

**Root cause:** PowerShell's `PSUseApprovedVerbs` rule checks every `FunctionDefinitionAst` node — functions defined with the `function` keyword — and verifies that the verb part (text before the first hyphen) is one of the [approved PowerShell verbs](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).

**Fix:** Rename the function to use an approved verb. Example:

```powershell
# BAD — 'Ensure' is not an approved verb:
function Ensure-Tool { ... }

# GOOD — use an approved verb:
function Assert-ToolAvailable { ... }
```

**Lowercase helpers (`say`, `warn`, `error`)**: These do not follow the Verb-Noun pattern at all. Rename them to use an approved Verb-Noun format:

```powershell
# BAD — no Verb-Noun pattern:
function say { Write-Output "$args" }

# GOOD — approved verb + descriptive noun:
function Write-Message { Write-Output "$args" }
```

**Command-name wrappers** (`python`, `bun`, `cargo`, etc.): Functions that intentionally shadow native commands must keep their exact lowercase name to function as replacements. Non-hyphenated lowercase names (`python`, `bun`, `node`, etc.) do NOT trigger `PSUseApprovedVerbs` (it only fires on Verb-Noun hyphenated names), but `node` DOES trigger `PSAvoidOverwritingBuiltInCmdlets` (it shadows a built-in cmdlet). Add the attribute INSIDE the function body immediately before `param()`:

```powershell
# check-suppress:SuppressMessageAttribute: PSAvoidOverwritingBuiltInCmdlets — intentional: shadows native node; warns to use bun equivalents
function node {
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
  param()
  ...
}
```

This is not an exemption — use inline suppression with a documented reason as per standard suppression rules. The comment syntax `# SuppressMessageAttribute('RuleId', '')` does NOT work — PSSA's `GetSuppressions` only reads `AttributeAst` from param blocks; comment-based suppressions are silently ignored (dead weight). The attribute MUST be placed inside the function body before `param()` (placing it on the `function` keyword line causes `UnexpectedAttribute` ParseErrors).

**`Add-ShellAlias` helper**: Functions that create aliases via `New-Item -Path Function:` use the PSFunction provider path and produce no `FunctionDefinitionAst`. The helper itself (`Add-ShellAlias`) uses the approved verb `Add-`. This is the canonical way to create function aliases without triggering the rule.

### `PSUseSingularNouns` — always use singular nouns

**Trigger:** Function or cmdlet name using a plural noun, e.g. `Get-VmRunningNames`.

**Root cause:** PowerShell convention requires function names to use singular nouns. PSSA's `PSUseSingularNouns` rule flags any function whose noun part appears grammatically plural (typically ending in 's', 'es', 'ies', or irregular plurals).

**Fix — two cases:**

1. **Function returns a single item** → use bare singular noun (e.g., `Get-Process`, `Get-Service`).
2. **Function returns multiple items** (collection/plurality) → use a **collection-indicating singular noun** — never a bare singular noun that misrepresents the return type.

**Allowed collection-indicating singular nouns:**

| Category             | Words                                                                                                       |
| -------------------- | ----------------------------------------------------------------------------------------------------------- |
| General collections  | List, Set, Collection, Array, Group, Batch, Bundle, Cluster                                                 |
| Key-value structures | Map, Dictionary, Hash, Hashtable, Index, Registry, Catalog, Table                                           |
| Data structures      | Queue, Stack, Vector, Matrix, Range, Buffer, Pool, Cache, Heap, Ring, Tree, Graph, Stream, Sequence, Series |
| Record-keeping       | Enum, Inventory, Manifest, Record, Store, Archive, Suite, Toolkit, Library, Report                          |
| Organizational       | Aggregate, Compilation, Overview, Summary                                                                   |

**Suppression:** Never. Do not suppress `PSUseSingularNouns`. Rename the function.

**Edge cases:** Words ending in 's' that are inherently singular (Status, alias, process, bus, focus, virus, analysis, basis, crisis, thesis, etc.) are not violations. PSSA's built-in dictionary handles most of these.

## Reference table

| Rule ID                                                    | Trigger                             | Fix strategy                                                                                                |
| ---------------------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `PSUseUsingScopeModifierInNewRunspaces`                    | `$using:VAR.Count` member access    | Assign `$using:` var to local, use `.Count` on local                                                        |
| `PSUseApprovedVerbs`                                       | Function name uses unapproved verb  | Rename to approved verb; lowercase helpers get Verb-Noun name; command-name wrappers add inline suppression |
| `PSUseSingularNouns`                                       | Function name uses plural noun      | Rename to singular noun: bare singular for single-return, collection-indicating singular for multi-return   |
| `PSUseDeclaredVarsMoreThanAssignments`                     | `$null = <cmd>` or `[void]<expr>`   | `> $null` redirect preferred, else annotate with `# check-suppress:SuppressMessageAttribute:`               |
| `PSPossibleIncorrectComparisonWithNull`                    | `$null = <cmd>`                     | `> $null` redirect preferred, else annotate with `# check-suppress:SuppressMessageAttribute:`               |
| `PSReviewUnusedParameter` / `PSAvoidUsingUnusedParameters` | Parameter not used in function body | Reassess parameter necessity; annotate `$null =` with `# check-suppress:SuppressMessageAttribute:`          |

## Adding a new rule policy

To document a new PSScriptAnalyzer rule policy:

1. Create a section `## <RuleId>` with:
   - **Trigger:** what code pattern causes the finding.
   - **Root cause:** why the rule fires.
   - **Fix:** the canonical fix strategy with a code example.
   - **Suppression:** when (if ever) suppression is acceptable, with the required justification format.
   - **Upstream:** link to any related PSSA issue/PR if relevant.
2. Add a row to the reference table above.
3. Verify the fix strategy works by testing against actual repo code.

## Annotation reference

Two coexisting annotation formats, both under the `# check-suppress:` prefix:

| Format                                                           | Class | Used for                                                                                                    |
| ---------------------------------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------- | --- | ----- |
| `# check-suppress:SuppressMessageAttribute: <RuleId> — <reason>` | A/C   | `$null =`, `[void]`, `[SuppressMessageAttribute]` attribute, and any comment-only suppression of PSSA rules |
| `# check-suppress:suppression_doc: <reason>`                     | B     | `2>$null`, `-ErrorAction SilentlyContinue`, empty `catch {}`, `                                             |     | true` |

Both are grep-able: `grep 'check-suppress:' **/*.ps1`

## B-class error suppression (stable)

The following patterns use `# check-suppress:suppression_doc:` format and are NOT changing:

- `2>$null` — stderr-only suppression
- `-ErrorAction SilentlyContinue` — suppressing non-terminating errors
- Empty `catch {}` — suppressing terminating errors
- `|| true` — shell-level error suppression

These are enforced by `check.ps1` step 17 and require a `# check-suppress:suppression_doc: <reason>` annotation.
