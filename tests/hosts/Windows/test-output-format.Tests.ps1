<#
.SYNOPSIS
  Pester tests for test.ps1 output format (pre-refactor).
  When test.ps1 is refactored (Phase 6b), update assertions.

.DESCRIPTION
  Validates current output format patterns for test.ps1:
  - Timing-only table
  - Generic failure/success messages
  - Absence of refactored features

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/test-output-format.Tests.ps1 -Passthru"
#>

$testPs1Path = Join-Path $PSScriptRoot '../../../scripts/test.ps1'
$testPs1Content = Get-Content -Path $testPs1Path -Raw

Describe 'Timing table format (pre-refactor)' {
  It 'uses say with step {0,2} and ms format' {
    $testPs1Content | Should -MatchExactly "say \(`"  step \{0,2\}: \{1,5\} ms`""
  }

  It 'has total timing line' {
    $testPs1Content | Should -MatchExactly "say \(`"  total:   \{0,5\} ms`""
  }
}

Describe 'Generic messages (pre-refactor)' {
  It 'has generic failure message' {
    $testPs1Content | Should -MatchExactly 'some tests failed'
  }

  It 'has generic success message' {
    $testPs1Content | Should -MatchExactly 'all tests passed\.'
  }
}

Describe 'Absence of refactored features (pre-refactor)' {
  It 'does not have combined status table' {
    $testPs1Content | Should -Not -MatchExactly '✓'
    $testPs1Content | Should -Not -MatchExactly '✗'
  }

  It 'does not have [Step N] prefix' {
    $testPs1Content | Should -Not -MatchExactly '\[Step '
  }

  It 'does not have test boundary markers' {
    $testPs1Content | Should -Not -MatchExactly '--- test output ---'
  }

  It 'does not have explicit failure summary' {
    $testPs1Content | Should -Not -MatchExactly 'Failed step'
  }
}
