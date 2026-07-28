<#
.SYNOPSIS
  PSScriptAnalyzer settings for repository check (pre-commit/lint) runs.

.DESCRIPTION
  This settings file is used by scripts/check-pwsh.ps1 during repository check
  runs (check.sh / check.ps1). It excludes rules that are prohibitively slow
  for fast pre-commit validation.

  Wall-clock benchmark (isolated single-pass runs, each in a fresh pwsh process,
  128 *.ps1 files, macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0):
    TEST (no slow rules excluded):                         56.3s, 501 diagnostics
    ex-A (exclude PSAvoidUsingCmdletAliases):              41.9s, 501 diagnostics
    ex-C (exclude PSUseCmdletCorrectly):                   57.1s, 501 diagnostics
    ex-S (exclude PSShouldProcess):                        43.2s, 501 diagnostics
    ex-A+C (exclude A+C):                                  31.7s, 501 diagnostics
    ex-A+S (exclude A+S):                                  27.9s, 501 diagnostics
    ex-C+S (exclude C+S):                                  47.7s, 501 diagnostics
    CHECK (exclude A+C+S+BOM):                              0.6s, 501 diagnostics
  All three slow rules use Get-Command internally per file — excluding them
  reduces check time from ~56s to sub-second. Remaining 60 rules: all <1.2s each.

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
        # Slow rules (~56s added wall-clock, see benchmark above):
        'PSAvoidUsingCmdletAliases'
        'PSUseCmdletCorrectly'
        'PSShouldProcess'
    )
}
