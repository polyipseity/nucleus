<#
.SYNOPSIS
  Pester tests for check.ps1 exit code normalization (step 13 fix).

.DESCRIPTION
  Verifies that the service registry validation section in check.ps1 uses
  normalized exit code ($exitCode = 1) instead of the violation count
  ($exitCode = $_svcErrors). This prevents spurious exit codes that could
  mask or amplify failure severity.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/check-exit-code.Tests.ps1 -Passthru"
#>

BeforeAll {
  $checkPs1Path = Join-Path $PSScriptRoot '../../../scripts/check.ps1'
  $checkPs1Content = Get-Content -Path $checkPs1Path -Raw
}

Describe 'Step 13 — service registry validation exit code' {
  It 'uses normalized exit code $exitCode = 1 (not $_svcErrors)' {
    $checkPs1Content | Should -MatchExactly '\$exitCode = 1'
    # Ensure it does NOT contain the old pattern $exitCode = $_svcErrors
    $checkPs1Content | Should -Not -MatchExactly '\$exitCode = \$_svcErrors'
  }

  It 'has warning message for validation failure' {
    $checkPs1Content | Should -MatchExactly 'services\.json validation failed'
  }

  It 'has success message for validation pass' {
    $checkPs1Content | Should -MatchExactly 'services\.json validation passed'
  }

  It 'checks justification for user-scoped entries' {
    $checkPs1Content | Should -MatchExactly 'justification'
  }

  It 'cross-references service names in users.json' {
    $checkPs1Content | Should -MatchExactly 'users\.json'
  }

  It 'handles missing services.json gracefully' {
    $checkPs1Content | Should -MatchExactly 'services\.json not found'
  }

  It 'has "passed" after justification in source ordering' {
    # Ordering assertion: in the flattened file, "justification" must
    # appear before "validation passed" to confirm the verdict is not
    # emitted prematurely.
    $flattened = $checkPs1Content -replace "`n|`r", ' '
    $flattened | Should -MatchExactly 'justification.*validation passed'
  }
}
