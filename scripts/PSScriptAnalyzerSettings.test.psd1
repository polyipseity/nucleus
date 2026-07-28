# ============================================================================
# WARNING: DO NOT MODIFY THIS FILE WITHOUT EXPLICIT PERMISSION
# ============================================================================
#
# This file controls which PSScriptAnalyzer rules are excluded during
# repository check runs (check.sh / check.ps1, step 2).
#
# Adding, removing, or changing ExcludeRules in this file without
# explicit user approval is FORBIDDEN. If you believe a rule should
# be excluded, ASK FIRST.
#
# Pre-existing rules that may trigger if exclusions are removed:
#   - PSAvoidUsingCmdletAliases        (excluded: slow, ~42s)
#   - PSUseCmdletCorrectly             (excluded: slow, ~57s)
#   - PSShouldProcess                  (excluded: slow, ~43s)
#   - PSUseBOMForUnicodeEncodedFile    (excluded: auto-fixable, low value)
# ============================================================================

<#
.SYNOPSIS
  PSScriptAnalyzer settings for full-coverage repository test runs.

.DESCRIPTION
  This settings file is used by scripts/check-pwsh.ps1 during repository test
  runs (test.sh / test.ps1). It provides full rule coverage — only
  PSUseBOMForUnicodeEncodedFile is excluded (that rule is auto-fixable by pwsh
  and rarely relevant for lint-only runs).

  Unlike scripts/PSScriptAnalyzerSettings.check.psd1, this file does NOT
  exclude the three slow rules (PSAvoidUsingCmdletAliases, PSUseCmdletCorrectly,
  PSShouldProcess). Test runs take ~56s on 128 *.ps1 files (all rules enabled).

  Wall-clock benchmark (isolated single-pass runs, each in a fresh pwsh process,
  128 *.ps1 files, macOS Apple Silicon, pwsh 7.6.3, PSScriptAnalyzer 1.25.0):
    TEST (no slow rules excluded):                         56.3s, 501 diagnostics
    CHECK (all three excluded):                              0.6s, 501 diagnostics

  Benchmark data:
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
