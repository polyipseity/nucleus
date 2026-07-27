<#
.SYNOPSIS
  PSScriptAnalyzer settings for repository check (pre-commit/lint) runs.

.DESCRIPTION
  This settings file is used by scripts/check-pwsh.ps1 during repository check
  runs (check.sh / check.ps1). It excludes rules that are prohibitively slow
  for fast pre-commit validation.

  Benchmark results (.agents/skills/pssa-rule-benchmark/pssa-rule-benchmark-results.json):
  - Platform: macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0
  - Files analyzed: 126 *.ps1 files
  - Total elapsed: 281.3s across 63 enabled rules
  - Two rules dominate: PSAvoidUsingCmdletAliases (157.9s, 56%) and
    PSShouldProcess (72.0s, 26%) — both are PSSA engine-internal
    Get-Command resolution overhead, not rule-logic slowdowns
  - Remaining 61 rules: ~51.4s combined (most <1s each)

  To re-benchmark after updating PSScriptAnalyzer:
    pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1
#>
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseBOMForUnicodeEncodedFile'
        # Slow rules (>50s each, 82% of lint time combined):
        'PSAvoidUsingCmdletAliases'
        'PSShouldProcess'
    )
}
