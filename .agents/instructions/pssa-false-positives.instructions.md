---
description: "Use when working with PSScriptAnalyzer lint results in PowerShell files. Documents known false positives, upstream issues/PRs, and verified workarounds."
name: "PSScriptAnalyzer False Positives"
applyTo: "**/*.ps1, scripts/PSScriptAnalyzerSettings.*.psd1"
---

# PSScriptAnalyzer false positives

## `PSUseUsingScopeModifierInNewRunspaces` with `$using:VAR.Count`

**Trigger:** Accessing a property/member on a `$using:` variable inside a `Start-Job` / `Start-ThreadJob` script block, e.g. `$using:PS1_FILES.Count`.

**Root cause:** The AST for `$using:PS1_FILES.Count` places the `VariableExpressionAst` (`$using:PS1_FILES`) under a `MemberExpressionAst`, **not** a `UsingExpressionAst`. The rule's `IsNonUsingNonSpecialVariableExpressionAst` predicate only checks the immediate parent, so it misses the `$using:` scope modifier in the ancestor chain and falsely flags it as undeclared.

**Upstream status:**
- [Issue #1504](https://github.com/PowerShell/PSScriptAnalyzer/issues/1504): General false-positive tracking (open since 2020)
- [PR #2005](https://github.com/PowerShell/PSScriptAnalyzer/pull/2005): Draft PR adding tests for the issue but no fix (May 2024)
- No dedicated bug report for member-access false positive exists; the scope-ancestor check has never been addressed upstream

**Workaround:** Assign the `$using:` variable to a local first, then use `.Count` (or other member access) on the local:

```powershell
# BEFORE — triggers false positive:
if ($using:PS1_FILES.Count -gt 0) { ... $using:PS1_FILES ... }

# AFTER — no warning:
$_ps1Files = $using:PS1_FILES
if ($_ps1Files.Count -gt 0) { ... $_ps1Files ... }
```

This works because the assignment creates a local variable that PSSA finds in its assignment-tracking collection. A separate bug (`yield break` instead of `continue` in `FindNonAssignedNonUsingVarAsts`) causes PSSA to stop checking all remaining variables once it finds a match in the assignment list, suppressing any further warnings for that block.

## `PSUseApprovedVerbs` with `New-Item -Path Function:` aliases

**Trigger:** Defining functions via the PSFunction provider path instead of the `function` keyword,
e.g. `New-Item -Path Function: -Name '-g' -Value { & git @Args } -Force`.

**Root cause:** `PSUseApprovedVerbs` only inspects `FunctionDefinitionAst` AST nodes — the node
produced by `function foo { ... }` syntax. `New-Item -Path Function:` creates a function through
the PSFunction provider machinery without producing a `FunctionDefinitionAst`, so the rule never
evaluates the function name against its approved-verb list. There is no AST node for the rule to
inspect, making this a deliberate structural bypass rather than a parser false positive.

**Workaround:** Wrap the provider-path call in a helper so call sites stay clean:

```powershell
function Add-ShellAlias { param([string]$Name, [scriptblock]$Value) $null = New-Item -Path Function: -Name $Name -Value $Value -Force }
Add-ShellAlias '-g' { & git @Args }
```

This eliminates 82 individual suppressions while keeping the rule satisfied. The rule cannot fire
because no alias definition produces a `FunctionDefinitionAst`.

## Additional known false-positive patterns (untested)

- `$env:VARNAME` inside script blocks — the rule may flag environment variable accesses (mentioned in issue #1504 comments)
- `$using:VAR` with any member/property access (`.Length`, `.Count`, `.Key`, etc.) — all trigger the same parent-chain check gap
