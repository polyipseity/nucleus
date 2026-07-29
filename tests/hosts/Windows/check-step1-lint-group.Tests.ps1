<#
.SYNOPSIS
  Pester tests for check.ps1 step 1 (Windows treefmt correspondence group).

.DESCRIPTION
  Validates that check.ps1 step 1 runs yamllint on YAML files instead of
  being a no-op stub, and documents the cross-platform correspondence with
  check.sh step 1 (treefmt).

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/check-step1-lint-group.Tests.ps1 -Passthru"
#>

BeforeAll {
    $script:checkContent = Get-Content -Raw -Path "$PWD/scripts/check.ps1"
}

Describe 'Step 1: Code formatting and linting (treefmt equivalent)' {
    It 'has yamllint invocation' {
        $script:checkContent | Should -MatchExactly 'yamllint'
    }

    It 'has correspondence anchor in step name' {
        $script:checkContent | Should -MatchExactly 'treefmt equivalent'
    }

    It 'has bidirectional docstring referencing POSIX treefmt' {
        $script:checkContent | Should -MatchExactly 'On POSIX, this check runs via.*treefmt'
    }

    It 'references check.sh in the documentation' {
        $script:checkContent | Should -MatchExactly 'See scripts/check.sh'
    }
}

Describe 'Pre-flight: yamllint tool availability' {
    It 'has yamllint in Ensure-Tool pre-flight block' {
        $script:checkContent | Should -MatchExactly "Assert-ToolAvailable -Name 'yamllint'"
    }
}
