<#
.SYNOPSIS
  PSScriptAnalyzer settings for full-coverage repository test runs.

.DESCRIPTION
  This settings file is used by scripts/check-pwsh.ps1 during repository test
  runs (test.sh / test.ps1). It provides full rule coverage — only
  PSUseBOMForUnicodeEncodedFile is excluded (that rule is auto-fixable by pwsh
  and rarely relevant for lint-only runs).

  Unlike scripts/PSScriptAnalyzerSettings.check.psd1, this file does NOT
  exclude the two slow rules (PSAvoidUsingCmdletAliases, PSShouldProcess).
  Test runs are expected to take longer (~3-4 min on 126 files).

  Benchmark results:
    pwsh .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark.ps1
    data: .agents/skills/pssa-rule-benchmark/pssa-rule-benchmark-results.json

  Related settings files (all intentionally separate — no deduplication):
    scripts/PSScriptAnalyzerSettings.check.psd1                   — pre-commit/lint (excludes slow rules)
    src/modules/configs/pwsh/PSScriptAnalyzerSettings.psd1       — interactive profile
    .agents/skills/pssa-rule-benchmark/PSScriptAnalyzerSettings.psd1 — benchmarking
#>
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
