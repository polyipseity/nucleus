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
    $script:checkContent = Get-Content -Raw -Path "$PWD/src/scripts/lib/framework-lib.ps1"
}

Describe 'Combined status table' {
    It 'has totalSteps variable' {
        $script:checkContent | Should -MatchExactly '\$totalSteps'
    }

    It 'uses combined format with step number and ms' {
        $script:checkContent | Should -MatchExactly '"  step \{0,2\}  \{1\}  \{2,5\} ms  \{3\}"'
    }

    It 'has total timing line' {
        $script:checkContent | Should -MatchExactly '"  total:   \{0,5\} ms"'
    }
}

Describe 'Step name files' {
    It 'writes step name files for 20 steps' {
        $script:checkContent | Should -MatchExactly 'step-\$Number\.name'
    }
}

Describe 'Generic messages' {
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

Describe '[Step N] prefix (Phase 5c)' {
    It 'has [Step N] prefix in Start-Job say/error' {
        # Look for [Step $($_step)] in say/error function definitions inside Start-Job blocks
        $script:checkContent | Should -MatchExactly '\[Step \$\(\$_step\)\]'
    }
}
