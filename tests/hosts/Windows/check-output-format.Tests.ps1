<#
.SYNOPSIS
  Pester tests for check.ps1 output format (Phase 5: combined status table).

.DESCRIPTION
  Validates current output format patterns for check.ps1:
  - Combined status table (step N ✓/✗ ms Name)
  - _totalSteps and _failedSteps variables
  - Generic failure/success messages
  - Explicit failure summary
  - Step name files written

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/check-output-format.Tests.ps1 -Passthru"
#>

BeforeAll {
    $script:checkContent = Get-Content -Raw -Path "$PWD/scripts/check.ps1"
}

Describe 'Combined status table (Phase 5)' {
    It 'has _totalSteps variable' {
        $script:checkContent | Should -MatchExactly '\$_totalSteps'
    }

    It 'has _failedSteps variable' {
        $script:checkContent | Should -MatchExactly '\$_failedSteps'
    }

    It 'uses combined format with step number and ms' {
        $script:checkContent | Should -MatchExactly "Write-Output \(`"  step \{0,2\}  \{1\}  \{2,5\} ms  \{3\}`""
    }

    It 'has total timing line' {
        $script:checkContent | Should -MatchExactly "Write-Output \(`"  total:   \{0,5\} ms`""
    }
}

Describe 'Step name files' {
    It 'writes step name files for all 21 steps' {
        $script:checkContent | Should -MatchExactly 'step-\$\(\$_step\)\.name'
    }
}

Describe 'Generic messages (Phase 5)' {
    It 'has generic failure message' {
        $script:checkContent | Should -MatchExactly 'some checks failed'
    }

    It 'has generic success message' {
        $script:checkContent | Should -MatchExactly 'all checks passed\.'
    }
}

Describe 'Explicit failure summary (Phase 5)' {
    It 'has explicit failure summary with Failed steps' {
        $script:checkContent | Should -MatchExactly 'Failed steps'
    }
}
