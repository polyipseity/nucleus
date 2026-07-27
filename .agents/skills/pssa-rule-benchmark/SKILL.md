---
name: pssa-rule-benchmark
description: 'Benchmark each PSScriptAnalyzer rule independently to identify slow rules and measure per-rule performance. Use when debugging slow lint runs, optimizing check-pwsh.ps1, or profiling PSSA rule timing.'
---

# PSScriptAnalyzer per-rule benchmarking

## When to use

- Debug why `check-pwsh.ps1` or `Invoke-ScriptAnalyzer` is slow
- Profile individual rule timing across the repository's `.ps1` files
- Compare performance between PSScriptAnalyzer versions
- Identify rules that dominate total lint time

## How it works

For each enabled rule, runs `Invoke-ScriptAnalyzer` on all tracked `.ps1` files with *only that rule* enabled (via `IncludeRules` + empty `Rules` hashtable). Measures elapsed wall-clock time per rule and saves incremental results as JSON.

### Known performance characteristics (benchmarked on macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0, 126 files × 63 rules)

- **Total wall-clock**: ~282s
- **Two rules dominate**: `PSAvoidUsingCmdletAliases` (~158s, 56%) and `PSShouldProcess` (~72s, 26%) — both involve `Get-Command` resolution per file
- **All other 61 rules**: each completes in <5s
- Results file: [pssa-rule-benchmark-results.json](./references/pssa-rule-benchmark-results.json)

## Procedure

1. Ensure you're in the repository root (scripts use `git ls-files` to discover `.ps1` files).

2. Run the benchmark:
   ```powershell
   pwsh .agents/skills/pssa-rule-benchmark/scripts/pssa-rule-benchmark.ps1
   ```
   Optionally specify a custom results path:
   ```powershell
   pwsh .agents/skills/pssa-rule-benchmark/scripts/pssa-rule-benchmark.ps1 -ResultsFile /tmp/my-results.json
   ```

3. The script outputs:
   - Per-rule progress with percentage (`[12/63 (19.0%)] PSAvoidUsingCmdletAliases`)
   - Per-rule elapsed time and diagnostic count
   - Top 10 slowest rules table
   - Bottom 5 fastest rules table

4. Results are saved incrementally after each rule — if the script is interrupted, partial results are still available.

## Script internals

- **Settings source**: Reads `PSScriptAnalyzerSettings.psd1` from `scripts/` for `Severity` and `ExcludeRules`
- **File discovery**: `git ls-files '*.ps1'` — only tracks version-controlled files
- **Per-rule invocation**: `$paths | Invoke-ScriptAnalyzer -Settings @{IncludeRules=@($ruleName); Rules=@{}}`
- **Measurement**: `[System.Diagnostics.Stopwatch]` per rule
- **Output**: Incremental `ConvertTo-Json | Set-Content`

## Interpreting results

The `ElapsedMs` field is wall-clock time — it includes pipeline overhead, module loading, and file I/O. The key insight is which rules are *disproportionately* slow relative to others. The two `Get-Command`-intensive rules are a known PSScriptAnalyzer design limitation; optimizing them would require changes to the analyzer engine, not the rule definitions.

## File layout

```
.agents/skills/pssa-rule-benchmark/
├── SKILL.md                                          # This file
├── scripts/
│   └── pssa-rule-benchmark.ps1                       # Benchmark runner
└── references/
    └── pssa-rule-benchmark-results.json              # Latest benchmark results (63 rules)
```
