---
name: pssa-rule-benchmark
description: "Benchmark each PSScriptAnalyzer rule independently to identify slow rules and measure per-rule performance. Use when debugging slow lint runs, optimizing check-pwsh.ps1, or profiling PSSA rule timing."
argument-hint: "[ResultsFile]"
---

# PSScriptAnalyzer per-rule benchmarking

## When to use

- Debug why `check-pwsh.ps1` or `Invoke-ScriptAnalyzer` is slow
- Profile individual rule timing across the repository's `.ps1` files
- Compare performance between PSScriptAnalyzer versions
- Identify rules that dominate total lint time

## Prerequisites

- `pwsh` 7+, `PSScriptAnalyzer`, and `git` on `PATH`
- Run from the repository root (script uses `git ls-files` for file discovery)
- Settings file `PSScriptAnalyzerSettings.psd1` is bundled in the skill folder — tweak `Severity` / `ExcludeRules` there

## Procedure

Run the benchmark:

```powershell
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1
```

Optionally write results elsewhere:

```powershell
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -ResultsFile /tmp/my-results.json
```

The script measures each enabled rule in isolation (via `IncludeRules` + empty `Rules` hashtable), outputs per-rule progress and timing, then prints top-10 / bottom-5 tables. Results are saved incrementally — partial output survives interruption.

### Known performance (macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0, 126 files × 63 rules)

| Metric                      | Value                                |
| --------------------------- | ------------------------------------ |
| Total wall-clock            | ~282s                                |
| `PSAvoidUsingCmdletAliases` | ~158s (56%) — `Get-Command` per file |
| `PSShouldProcess`           | ~72s (26%) — `Get-Command` per file  |
| All other 61 rules          | each <5s                             |

## Interpreting results

`ElapsedMs` is wall-clock time (pipeline + I/O + module load overhead). The two `Get-Command`-intensive rules are a PSScriptAnalyzer engine limitation, not the rule definitions themselves.

## Internals

- **Settings**: reads bundled `PSScriptAnalyzerSettings.psd1` for `Severity` and `ExcludeRules`
- **File discovery**: `git ls-files '*.ps1'` — version-controlled files only
- **Per-rule invocation**: `$paths | Invoke-ScriptAnalyzer -Settings @{IncludeRules=@($ruleName); Rules=@{}}`
- **Measurement**: `[System.Diagnostics.Stopwatch]` per rule
- **Output**: incremental `ConvertTo-Json | Set-Content`

## File layout

```
.agents/skills/pssa-rule-benchmark/
├── SKILL.md                               # This file
├── PSScriptAnalyzerSettings.psd1          # Rule severity/exclusion config
├── pssa-rule-benchmark.ps1                # Benchmark runner
└── pssa-rule-benchmark-results.json       # Latest results (63 rules) (reference data)
```
