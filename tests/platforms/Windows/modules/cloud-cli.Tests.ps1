<#
.SYNOPSIS
  Pester tests for the nucleus-cloud CLI script (scripts/cloud.ps1).

.DESCRIPTION
  Validates the list-replicas flag parity and action validation for the cloud CLI.
  The tests run the script from the repository root so repo-root resolution and the
  real user registry are exercised, matching the POSIX CLI list-surface coverage.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/cloud-cli.Tests.ps1 -Output Detailed"
#>

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
  $script:CloudScript = Join-Path $script:RepoRoot 'scripts/cloud.ps1'

  function Invoke-CloudCli {
    <#
    .SYNOPSIS
      Runs scripts/cloud.ps1 and captures output and exit code.
    #>
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = & pwsh -NoProfile -File $script:CloudScript @Arguments 2>&1
      $exitCode = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $previousPreference
    }

    $lines = @(
      $output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
          $_.ToString()
        }
        else {
          [string]$_
        }
      }
    )

    [pscustomobject]@{
      ExitCode = $exitCode
      Lines    = $lines
      Text     = ($lines -join "`n")
    }
  }
}

Describe 'scripts/cloud.ps1' {
  BeforeAll {
    Push-Location -LiteralPath $script:RepoRoot
  }

  AfterAll {
    Pop-Location
  }

  Context 'list replicas' {
    It 'exits 0 for --list-replicas and prints the same replica ids as -ListReplicas' {
      $long = Invoke-CloudCli -Arguments @('--list-replicas')
      $long.ExitCode | Should -Be 0

      $short = Invoke-CloudCli -Arguments @('-ListReplicas')
      $short.ExitCode | Should -Be 0

      $long.Lines | Should -Not -BeNullOrEmpty -Because '--list-replicas must print configured replica ids'
      @($long.Lines | Where-Object { $_ -ne '' }).Count | Should -BeGreaterThan 0
      $long.Text | Should -Be $short.Text
    }

    It 'keeps -ListReplicas working' {
      $result = Invoke-CloudCli -Arguments @('-ListReplicas')
      $result.ExitCode | Should -Be 0
      @($result.Lines | Where-Object { $_ -ne '' }).Count | Should -BeGreaterThan 0
    }
  }

  Context 'action validation' {
    It 'fails for an unknown action and names the valid set' {
      $result = Invoke-CloudCli -Arguments @('bogus')
      $result.ExitCode | Should -Not -Be 0
      $result.Text | Should -Match '(?s)setup.*reset.*sync.*status.*restart'
    }
  }
}
