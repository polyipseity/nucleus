<#
.SYNOPSIS
  PSScriptAnalyzer settings for interactive pwsh sessions.

.DESCRIPTION
  This file is the interactive-profile copy, symlinked to
  ~/.config/powershell/PSScriptAnalyzerSettings.psd1 by Home Manager
  (see src/modules/pwsh.nix).

  It provides full rule coverage for interactive use, matching the
  test/CI configuration (scripts/PSScriptAnalyzerSettings.test.psd1).
  Only PSUseBOMForUnicodeEncodedFile is excluded.

  CI-specific settings files:
    scripts/PSScriptAnalyzerSettings.check.psd1  — pre-commit checks
    scripts/PSScriptAnalyzerSettings.test.psd1   — full coverage tests
    .agents/skills/pssa-rule-benchmark/PSScriptAnalyzerSettings.psd1 — benchmarking

  All settings files are intentionally separate — no deduplication. Each serves
  a distinct audience (CI speed, full test coverage, interactive profile,
  benchmarking) and must stay independent.
#>
@{
    Severity = @('Error', 'Warning', 'Information')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
