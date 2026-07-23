<#
.SYNOPSIS
    Regression tests for PATH SetEnvironmentVariable audit findings.
.DESCRIPTION
    Confirms that no `[Environment]::SetEnvironmentVariable` call targeting
    "PATH" remains anywhere in the Windows PowerShell codebase.  The audit
    determined that deterministic binary paths (Join-Path $HOME) should be
    used instead of PATH registration, and the Set-NucleusUserPathEntry
    helper was removed entirely.
.NOTES
    Also verifies no Set-NucleusUserPathEntry references remain in case a
    stale call site was overlooked.
    Exit codes: 0 on success; 1 on failure
#>

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
$WindowsModulesDir = Join-Path $RepoRoot "src\hosts\Windows\modules"
$WindowsScriptsDir = Join-Path $RepoRoot "src\hosts\Windows"

Describe "No PATH SetEnvironmentVariable calls remain" {
  It "no [Environment]::SetEnvironmentVariable('PATH' in Windows modules" {
    $psFiles = Get-ChildItem -Path $WindowsModulesDir -Recurse -Filter "*.ps1" | Select-Object -ExpandProperty FullName
    $violations = @()
    foreach ($file in $psFiles) {
      $content = Get-Content -Raw -Path $file
      if ($content -match [regex]::Escape('[Environment]::SetEnvironmentVariable("PATH"')) {
        $violations += $file
      }
    }
    $violations.Count | Should -Be 0 -Because "SetEnvironmentVariable for PATH was eliminated; use deterministic binary paths instead"
  }

  It "no [Environment]::SetEnvironmentVariable('PATH' in apply.ps1" {
    $applyPath = Join-Path $WindowsScriptsDir "apply.ps1"
    $content = Get-Content -Raw -Path $applyPath
    $content | Should -Not -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("PATH"'))
  }
}

Describe "No Set-NucleusUserPathEntry references remain" {
  It "no dot-source of Set-NucleusUserPathEntry in apply.ps1" {
    $applyPath = Join-Path $WindowsScriptsDir "apply.ps1"
    $content = Get-Content -Raw -Path $applyPath
    $content | Should -Not -Match ('Set-NucleusUserPathEntry')
  }

  It "no Set-NucleusUserPathEntry calls in any module" {
    $psFiles = Get-ChildItem -Path $WindowsModulesDir -Recurse -Filter "*.ps1" | Select-Object -ExpandProperty FullName
    $violations = @()
    foreach ($file in $psFiles) {
      $content = Get-Content -Raw -Path $file
      if ($content -match 'Set-NucleusUserPathEntry') {
        $violations += $file
      }
    }
    $violations.Count | Should -Be 0 -Because "Set-NucleusUserPathEntry helper was removed"
  }
}
