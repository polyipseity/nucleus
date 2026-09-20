<#
.SYNOPSIS
    Pester parity tests for Windows env var wiring that needs no Nix toolchain.
.DESCRIPTION
    Compares the Windows DSC files, Sync-ShellProfile.ps1 and apply.ps1 against
    each other. The assertions that need the Nix catalog — which vars are
    Windows-applicable and in which scope — live in
    tests/integration/env-parity-tests.nix and run in the Nix test lane, because
    a Windows host has no Nix toolchain to evaluate the catalog with.

    Designed to fail if:
    - CC, CXX or LD move back out of the Machine-scope DSC file.
    - apply.ps1 persists NUCLEUS_HOST instead of leaving it to the DSC file.
.NOTES
    Requires: nothing beyond the repository checkout.
    Exit codes: 0 on success; 1 on failure
#>

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

BeforeAll {
  # Paths and helpers must be defined inside BeforeAll: Pester v5 does not make
  # script-scope definitions visible to It blocks under Invoke-Pester.
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $script:UserDscFile = Join-Path $RepoRoot "src\hosts\Windows\user\env.dsc.yml"
  $script:SystemDscFile = Join-Path $RepoRoot "src\hosts\Windows\system\env.dsc.yml"

  # ---- Helpers ----

  # Parse DSC YAML and return all Environment resource names.
  function Get-DscEnvVarNameList {
    param ([string]$DscPath)
    if (-not (Test-Path $DscPath)) {
      throw "DSC file not found: $DscPath"
    }
    $yaml = Get-Content -Raw -Path $DscPath
    # Minimal YAML parser: extract name from Microsoft.Windows.Environment/Variable resources.
    $resources = [regex]::Matches($yaml, '(?s)resource:\s*Microsoft\.Windows\.Environment/Variable.*?settings:\s*\n(.*?)(?=\n    - resource|\n    #|$)')
    $names = @()
    foreach ($match in $resources) {
      $settingsBlock = $match.Groups[1].Value
      $nameMatch = [regex]::Match($settingsBlock, 'name:\s*(.+)')
      if ($nameMatch.Success) {
        $names += $nameMatch.Groups[1].Value.Trim()
      }
    }
    return $names
  }

  # Extract profile-only vars (CC, CXX, LD) from Sync-ShellProfile.ps1.
  function Get-ProfileEnvVarNameList {
    $profilePath = Join-Path $RepoRoot "src\platforms\Windows\modules\user\Sync-ShellProfile.ps1"
    $content = Get-Content -Raw -Path $profilePath
    $names = @()
    # Match $env:VARNAME patterns in the PowerShell heredoc
    $found = [regex]::Matches($content, '\$env:(\w+)\s*=')
    foreach ($m in $found) {
      $names += $m.Groups[1].Value
    }
    return $names | Select-Object -Unique
  }

  # Read apply.ps1 content (used by multiple tests).
  function Get-ApplyPs1Content {
    $applyPath = Join-Path $RepoRoot "src\hosts\Windows\apply.ps1"
    return Get-Content -Raw -Path $applyPath
  }
}

Describe "Windows env var wiring parity" {
  Context "DSC files" {
    It "user/env.dsc.yml exists and is readable" {
      $script:UserDscFile | Should -Exist
    }

    It "system/env.dsc.yml exists and is readable" {
      $script:SystemDscFile | Should -Exist
    }
  }

  Context "Shell profile parity" {
    It "Sync-ShellProfile.ps1 no longer sets CC, CXX, LD (moved to Machine-scope DSC)" {
      $profileVars = Get-ProfileEnvVarNameList
      $profileVars | Should -Not -Contain "CC"
      $profileVars | Should -Not -Contain "CXX"
      $profileVars | Should -Not -Contain "LD"
    }

    It "CC, CXX, LD are in system/env.dsc.yml at Machine scope" {
      $dscVars = Get-DscEnvVarNameList -DscPath $script:SystemDscFile
      $dscVars | Should -Contain "CC"
      $dscVars | Should -Contain "CXX"
      $dscVars | Should -Contain "LD"
    }
  }

  Context "apply.ps1 parity" {
    It "apply.ps1 sets NUCLEUS_HOST to Windows" {
      $content = Get-ApplyPs1Content
      $content | Should -Match ('NUCLEUS_HOST.*=.*"Windows"')
    }

    It "apply.ps1 persists NUCLEUS_REPO_ROOT via SetEnvironmentVariable (Machine scope)" {
      $content = Get-ApplyPs1Content
      # NUCLEUS_REPO_ROOT is set dynamically per-activation (not via DSC),
      # so the test verifies the Machine-scope SetEnvironmentVariable call
      # exists rather than checking a specific value.
      $content | Should -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $repoRoot, "Machine")'))
    }

    It "apply.ps1 does not broadcast env change notification (removed)" {
      $content = Get-ApplyPs1Content
      $content | Should -Not -Match ('Send-NucleusEnvChangeNotification')
    }
  }

  Context "apply.ps1 NUCLEUS_HOST handling" {
    It "sets process-level env var only (no registry persistence in apply.ps1)" {
      $content = Get-ApplyPs1Content
      $content | Should -Match ([regex]::Escape('$env:NUCLEUS_HOST = "Windows"'))
    }

    It "does not persist NUCLEUS_HOST via SetEnvironmentVariable (handled by system/env.dsc.yml)" {
      $content = Get-ApplyPs1Content
      $content | Should -Not -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_HOST"'))
    }

    It "does not read persisted NUCLEUS_HOST value (delegated to DSC)" {
      $content = Get-ApplyPs1Content
      $content | Should -Not -Match ([regex]::Escape('GetEnvironmentVariable("NUCLEUS_HOST"'))
    }

    It "post-DSC does not clear User-scope NUCLEUS_HOST (never written in first place)" {
      $content = Get-ApplyPs1Content
      $content | Should -Not -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_HOST", $null, "User")'))
    }
  }

  Context "apply.ps1 NUCLEUS_REPO_ROOT handling" {
    It "reads current Machine scope value for compare" {
      $content = Get-ApplyPs1Content
      $content | Should -Match ([regex]::Escape('[Environment]::GetEnvironmentVariable("NUCLEUS_REPO_ROOT", "Machine")'))
      $content | Should -Match ([regex]::Escape('if ($existingRoot -ne $repoRoot)'))
    }

    It "writes Machine scope directly if value changed (no post-DSC promotion needed)" {
      $content = Get-ApplyPs1Content
      $content | Should -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $repoRoot, "Machine")'))
      $content | Should -Not -Match ([regex]::Escape('Write-Warning "apply: cannot promote NUCLEUS_REPO_ROOT to Machine scope'))
    }

    It "clears stale User scope value after Machine scope write" {
      $content = Get-ApplyPs1Content
      $content | Should -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $null, "User")'))
    }
  }
}
