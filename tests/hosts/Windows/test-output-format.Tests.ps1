<#
.SYNOPSIS
  Pester tests for test.ps1 output format (Phase 6b: combined status table).

.DESCRIPTION
  Validates current output format patterns for test.ps1:
  - Combined status table (step N ✓/✗ ms Name)
  - _totalSteps and _failedSteps variables
  - Generic failure/success messages
  - Explicit failure summary
  - Step name files written

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/test-output-format.Tests.ps1 -Passthru"
#>

BeforeAll {
    $script:testContent = Get-Content -Raw -Path "$PWD/src/scripts/lib/step-runner.ps1"
}

Describe 'Combined status table' {
    It 'has totalSteps variable' {
        $script:testContent | Should -MatchExactly '\$totalSteps'
    }

    It 'uses combined format with step number and ms' {
        $script:testContent | Should -MatchExactly '"  step \{0,2\}  \{1\}  \{2,5\} ms  \{3\}"'
    }

    It 'has total timing line' {
        $script:testContent | Should -MatchExactly '"  total:   \{0,5\} ms"'
    }
}

Describe 'Step name files' {
    It 'writes step name files for 4 steps' {
        $script:testContent | Should -MatchExactly 'step-\$Number\.name'
    }
}

Describe 'Generic messages' {
    It 'has generic failure message' {
        $script:testContent | Should -MatchExactly 'some tests failed'
    }

    It 'has generic success message' {
        $script:testContent | Should -MatchExactly 'all tests passed\.'
    }
}

Describe 'Explicit failure summary (Phase 6b)' {
    It 'has explicit failure summary with Failed steps' {
        $script:testContent | Should -MatchExactly 'Failed steps'
    }
}
