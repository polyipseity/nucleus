<#
.SYNOPSIS
  PSScriptAnalyzer settings for per-rule benchmarking.

.DESCRIPTION
  This settings file is bundled in the pssa-rule-benchmark skill. It matches
  the full-coverage configuration (scripts/PSScriptAnalyzerSettings.test.psd1)
  but is intentionally separate — the skill must remain self-contained and
  independent of repo layout.

  Related settings files (all intentionally separate — no deduplication):
    scripts/PSScriptAnalyzerSettings.check.psd1         — pre-commit/lint (excludes slow rules)
    scripts/PSScriptAnalyzerSettings.test.psd1          — full-coverage test runs
    src/modules/configs/pwsh/PSScriptAnalyzerSettings.psd1 — interactive profile
#>
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
