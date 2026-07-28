<#
.SYNOPSIS
  PSScriptAnalyzer settings for repository check (pre-commit/lint) runs.

.DESCRIPTION
  This settings file is used by scripts/check-pwsh.ps1 during repository check
  runs (check.sh / check.ps1). It excludes rules that are prohibitively slow
  for fast pre-commit validation.

  Benchmark results (.agents/skills/pssa-rule-benchmark/pssa-rule-benchmark-results.json):
  - Platform: macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0
  - Files analyzed: 128 *.ps1 files
  - Total elapsed: 681.2s across 63 rules × 3 runs (seed 442497198)
  - Three rules dominate the per-run cost:
    PSAvoidUsingCmdletAliases (~67.2s), PSUseCmdletCorrectly (~43.3s),
    PSShouldProcess (~42.8s) — all are PSSA engine-internal
    Get-Command resolution overhead, not rule-logic slowdowns
  - Remaining 60 rules: all <1.2s each

  To re-benchmark after updating PSScriptAnalyzer:
    pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1

  Related settings files (all intentionally separate — no deduplication):
    scripts/PSScriptAnalyzerSettings.test.psd1                   — full-coverage test runs
    src/modules/configs/pwsh/PSScriptAnalyzerSettings.psd1       — interactive profile
    .agents/skills/pssa-rule-benchmark/PSScriptAnalyzerSettings.psd1 — benchmarking
#>
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseBOMForUnicodeEncodedFile'
        # Slow rules (aggregate >150s, ~86% of total lint time):
        'PSAvoidUsingCmdletAliases'
        'PSUseCmdletCorrectly'
        'PSShouldProcess'
    )
}
