<#
.SYNOPSIS
  Pester tests for check.ps1 output format (pre-refactor).
  When check.ps1 is refactored (Phase 5), update assertions.

.DESCRIPTION
  Validates current output format patterns for check.ps1:
  - Timing-only table (say "  step N: X ms")
  - Generic failure/success messages
  - Absence of refactored features (combined table, [Step N], boundaries, failure summary)

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/check-output-format.Tests.ps1 -Passthru"
#>

$checkPs1Path = Join-Path $PSScriptRoot '../../../scripts/check.ps1'
$checkPs1Content = Get-Content -Path $checkPs1Path -Raw

Describe 'Timing table format (pre-refactor)' {
  It 'uses say with step {0,2} and ms format' {
    $checkPs1Content | Should -MatchExactly "say \(`"  step \{0,2\}: \{1,5\} ms`""
  }

  It 'has total timing line' {
    $checkPs1Content | Should -MatchExactly "say \(`"  total:   \{0,5\} ms`""
  }
}

Describe 'Generic messages (pre-refactor)' {
  It 'has generic failure message' {
    $checkPs1Content | Should -MatchExactly 'some checks failed'
  }

  It 'has generic success message' {
    $checkPs1Content | Should -MatchExactly 'all checks passed\.'
  }
}

Describe 'Absence of refactored features (pre-refactor)' {
  It 'does not have combined status table' {
    $checkPs1Content | Should -Not -MatchExactly '✓'
    $checkPs1Content | Should -Not -MatchExactly '✗'
  }

  It 'does not have [Step N] prefix' {
    $checkPs1Content | Should -Not -MatchExactly '\[Step '
  }

  It 'does not have test boundary markers' {
    $checkPs1Content | Should -Not -MatchExactly '--- test output ---'
  }

  It 'does not have explicit failure summary' {
    $checkPs1Content | Should -Not -MatchExactly 'Failed step'
  }
}
