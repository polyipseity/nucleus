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
4. **Avoid `[SuppressMessageAttribute('RuleId', '')]` attribute.** It is too coarse — applies to the entire scope (function/file). Prefer `$null =` or `[void]` with `# check-suppress:SuppressMessageAttribute:` annotation. Only use the attribute when there is literally no code path to annotate (e.g., a parameter that appears unused at file scope). When unavoidable, must minimize rules covered (list specific rule IDs, no wildcards) and scope covered (target the narrowest possible function or script block, never file-wide).
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

### `PSUseApprovedVerbs` with `New-Item -Path Function:` aliases

**Trigger:** Defining functions via the PSFunction provider path instead of the `function` keyword,
e.g. `New-Item -Path Function: -Name '-g' -Value { & git @Args } -Force`.

**Root cause:** `PSUseApprovedVerbs` only inspects `FunctionDefinitionAst` AST nodes — the node
produced by `function foo { ... }` syntax. `New-Item -Path Function:` creates a function through
the PSFunction provider machinery without producing a `FunctionDefinitionAst`, so the rule never
evaluates the function name against its approved-verb list. There is no AST node for the rule to
inspect, making this a deliberate structural bypass rather than a parser false positive.

**Fix:** Wrap the provider-path call in a helper so call sites stay clean:

```powershell
function Add-ShellAlias { param([string]$Name, [scriptblock]$Value) $null = New-Item -Path Function: -Name $Name -Value $Value -Force }
Add-ShellAlias '-g' { & git @Args }
```

This eliminates individual suppressions while keeping the rule satisfied. The rule cannot fire
because no alias definition produces a `FunctionDefinitionAst`.

## Reference table

| Rule ID | Trigger | Fix strategy |
|---------|---------|-------------|
| `PSUseUsingScopeModifierInNewRunspaces` | `$using:VAR.Count` member access | Assign `$using:` var to local, use `.Count` on local |
| `PSUseApprovedVerbs` | Function aliases via `New-Item -Path Function:` | Wrap in `Add-ShellAlias` helper |
| `PSUseDeclaredVarsMoreThanAssignments` | `$null = <cmd>` or `[void]<expr>` | `> $null` redirect preferred, else annotate with `# check-suppress:SuppressMessageAttribute:` |
| `PSPossibleIncorrectComparisonWithNull` | `$null = <cmd>` | `> $null` redirect preferred, else annotate with `# check-suppress:SuppressMessageAttribute:` |
| `PSReviewUnusedParameter` / `PSAvoidUsingUnusedParameters` | Parameter not used in function body | Reassess parameter necessity; annotate `$null =` with `# check-suppress:SuppressMessageAttribute:` |

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

| Format | Class | Used for |
|--------|-------|----------|
| `# check-suppress:SuppressMessageAttribute: <RuleId> — <reason>` | A/C | `$null =`, `[void]`, `[SuppressMessageAttribute]` attribute, and any comment-only suppression of PSSA rules |
| `# check-suppress:suppression_doc: <reason>` | B | `2>$null`, `-ErrorAction SilentlyContinue`, empty `catch {}`, `|| true` |

Both are grep-able: `grep 'check-suppress:' **/*.ps1`

## B-class error suppression (stable)

The following patterns use `# check-suppress:suppression_doc:` format and are NOT changing:

- `2>$null` — stderr-only suppression
- `-ErrorAction SilentlyContinue` — suppressing non-terminating errors
- Empty `catch {}` — suppressing terminating errors
- `|| true` — shell-level error suppression

These are enforced by `check.ps1` step 17 and require a `# check-suppress:suppression_doc: <reason>` annotation.
