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
- The two-script split (`invoke-pssa-rule.ps1` + `pssa-rule-benchmark.ps1`) must stay together in the same directory

## Procedure

Run the benchmark:

```powershell
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1
```

Optionally tune runs or output path:

```powershell
# 5 runs per rule (default: 3)
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -Runs 5

# Write results elsewhere
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -ResultsFile /tmp/my-results.json

# Skip existing rules (resume after partial run)
pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1 -SkipExisting
```

The benchmark launches a **separate `pwsh` subprocess per task**, each running `invoke-pssa-rule.ps1` with `-RuleName` set. This ensures complete isolation — no cross-rule state leaks, no cached AST or module state. Each subprocess imports `PSScriptAnalyzer` fresh and runs `Invoke-ScriptAnalyzer` against all repository `.ps1` files using the given rule in isolation (via `IncludeRules` + empty `Rules` hashtable). Subprocess output (JSON) is parsed; if parsing fails or the subprocess exits non-zero, the error is recorded and the run continues.

The task execution order is **globally randomized** using a printed seed (for reproducibility). Each task outputs progress: `[N/189 (P%)] RuleName (run R/R)` with elapsed time and diagnostic count. Results are checkpoint-incremented every 10 tasks — partial output survives interruption.

### Known performance (macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0, 128 files × 63 rules × 3 runs)

| Metric                         | Mean  | Max   | StdDev | Notes                                  |
| ------------------------------ | ----- | ----- | ------ | -------------------------------------- |
| **Total wall-clock**           | —     | ~681s | —      | 189 tasks randomized                   |
| `PSAvoidUsingCmdletAliases`    | 67.2s | 98.3s | 22.6s  | High variance — `Get-Command` per file |
| `PSUseCmdletCorrectly`         | 43.3s | 62.4s | 13.9s  | `Get-Command` per file                 |
| `PSShouldProcess`              | 42.8s | 54.0s | 8.4s   | `Get-Command` per file                 |
| `PSUseConstrainedLanguageMode` | 1.1s  | 2.9s  | 1.2s   | Spikes on constrained-mode checks      |
| All other 59 rules             | <1.2s | <1.4s | —      | Bulk completes in ~190s                |

The three slow rules (`PSAvoidUsingCmdletAliases`, `PSUseCmdletCorrectly`, `PSShouldProcess`) together consume ~77% of total benchmark time. Their slowness is a PSScriptAnalyzer engine limitation (each queries `Get-Command` per file), not the rule definitions themselves. `PSAvoidUsingCmdletAliases` shows high run-to-run variance (45–98s), suggesting sensitivity to system load / AMT JIT warmup.

## Interpreting results

`ElapsedMs` is wall-clock time (pipeline + I/O + module load overhead). The two `Get-Command`-intensive rules are a PSScriptAnalyzer engine limitation, not the rule definitions themselves.

## Internals

- **Script split**: `invoke-pssa-rule.ps1` measures a single rule in a fresh process; `pssa-rule-benchmark.ps1` orchestrates the task matrix, spawns subprocesses, and aggregates results.
- **Settings**: reads bundled `PSScriptAnalyzerSettings.psd1` for `Severity` and `ExcludeRules`
- **File discovery**: `git ls-files '*.ps1'` — version-controlled files only
- **Task matrix**: all enabled rules × `$Runs` (default 3) = $N$ tasks, then **shuffled** with `Sort-Object { Get-Random }` and a printed seed for reproducibility
- **Subprocess runner** (`invoke-pssa-rule.psl`): imports `PSScriptAnalyzer`, calls `Invoke-ScriptAnalyzer` with `-IncludeRules @($ruleName) -ExcludeRules @()`, measures with `[System.Diagnostics.Stopwatch]`, outputs JSON to stdout via `ConvertTo-Json -Compress`. Exit 0 on success, 1 on failure.
- **Subprocess spawning** (`pssa-rule-benchmark.ps1`): `System.Diagnostics.Process` with `RedirectStandardOutput=true`, `RedirectStandardError=true`, 600s timeout per task. Stdout parsed from JSON; stderr captured to `ErrorMessage` on parse failure.
- **Aggregation**: per rule across $R$ runs: `MeanMs`, `MinMs`, `MaxMs`, `StdDevMs` (population stddev), `MedianMs`, `MeanDiagCount`. Raw per-run data included in `RawData` array.
- **Incremental output**: raw results saved to `$ResultsFile.raw` every 10 tasks; deleted on success. Final aggregated JSON written to `$ResultsFile`.

## File layout

```text
.agents/skills/pssa-rule-benchmark/
├── SKILL.md                               # This file
├── PSScriptAnalyzerSettings.psd1          # Rule severity/exclusion config
├── invoke-pssa-rule.ps1                   # Single-rule subprocess runner
├── pssa-rule-benchmark.ps1                # Benchmark orchestrator
└── pssa-rule-benchmark-results.json       # Latest aggregated results (63 rules × 3 runs) (reference data)
```
