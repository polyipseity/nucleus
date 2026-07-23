<#
.SYNOPSIS
    Pester tests verifying Camilla service scripts use deterministic binary paths.
.DESCRIPTION
    After the SetEnvironmentVariable audit, Camilla service scripts no longer
    search PATH via Get-Command.  Instead they compute the binary path
    deterministically via Join-Path $HOME (matching the install dir used by
    the corresponding Invoke-* setup scripts).  These tests verify the new
    pattern is in place and no Get-Command calls remain.
.NOTES
    Exit codes: 0 on success; 1 on failure
#>

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
$CamillaDspService = Join-Path $RepoRoot "src\hosts\Windows\modules\user\Sync-CamillaDSPService.ps1"
$CamillaGuiService = Join-Path $RepoRoot "src\hosts\Windows\modules\user\Sync-CamillaGUIService.ps1"

Describe "CamillaDSP service script binary path resolution" {
  It "uses deterministic path from Join-Path $HOME" {
    $content = Get-Content -Raw -Path $CamillaDspService
    $content | Should -Match ([regex]::Escape('Join-Path $HOME ".local\bin\camilladsp.exe"'))
  }

  It "uses Test-Path instead of Get-Command for binary existence check" {
    $content = Get-Content -Raw -Path $CamillaDspService
    $content | Should -Not -Match ('Get-Command.*camilladsp')
    $content | Should -Match ([regex]::Escape('Test-Path $camilladspBin'))
  }

  It "has no Get-Command calls" {
    $content = Get-Content -Raw -Path $CamillaDspService
    $content | Should -Not -Match ('Get-Command')
  }
}

Describe "CamillaGUI service script binary path resolution" {
  It "uses deterministic path from Join-Path $HOME" {
    $content = Get-Content -Raw -Path $CamillaGuiService
    $content | Should -Match ([regex]::Escape('Join-Path $HOME ".local\bin\camillagui_backend\camillagui_backend.exe"'))
  }

  It "uses Test-Path instead of Get-Command for binary existence check" {
    $content = Get-Content -Raw -Path $CamillaGuiService
    $content | Should -Not -Match ('Get-Command.*camillagui')
    $content | Should -Match ([regex]::Escape('Test-Path $camillaguiBin'))
  }

  It "has no Get-Command calls" {
    $content = Get-Content -Raw -Path $CamillaGuiService
    $content | Should -Not -Match ('Get-Command')
  }
}
