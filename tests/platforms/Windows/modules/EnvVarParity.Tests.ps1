<#
.SYNOPSIS
    Pester parity tests verifying Windows env vars match the Nix catalog.
.DESCRIPTION
    Evaluates the Nix centralized env var catalog (src/modules/lib/env-catalog.nix)
    and compares every Windows-relevant variable against the Windows DSC
    registry (user/env.dsc.yml) and Sync-ShellProfile.ps1.

    Designed to fail if:
    - A catalog var expected on Windows has no DSC or profile entry.
    - A DSC var has no counterpart in the Nix catalog (would drift silently).
.NOTES
    Requires: result/env-parity-manifest.json materialized by test step
    06-windows-pester.ps1 from tests/integration/env-parity-tests.nix.
    Exit codes: 0 on success; 1 on failure
#>

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

# Paths
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
$UserDscFile = Join-Path $RepoRoot "src\hosts\Windows\user\env.dsc.yml"
$SystemDscFile = Join-Path $RepoRoot "src\hosts\Windows\system\env.dsc.yml"
$ManifestFile = Join-Path $RepoRoot "result\env-parity-manifest.json"
# $CatalogNixFile intentionally omitted; unused

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

# Evaluate the Nix catalog JSON manifest (materialized by 06-windows-pester.ps1).
function Get-NixCatalogManifest {
  param ([string]$ManifestPath)
  if (-not (Test-Path $ManifestPath)) {
    throw "env-parity manifest not found at $ManifestPath — run test step 06-windows-pester to materialize it"
  }
  return Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
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

BeforeAll {
  # No variable assignments here; all vars are at script scope for PSScriptAnalyzer visibility.
}

Describe "Windows env var parity with Nix catalog" {
  Context "DSC parity — user scope" {
    It "user/env.dsc.yml exists and is readable" {
      $UserDscFile | Should -Exist
    }

    It "catalog manifest evaluates successfully" {
      { $script:Manifest = Get-NixCatalogManifest -ManifestPath $ManifestFile } | Should -Not -Throw
      $script:Manifest | Should -Not -BeNullOrEmpty
    }

    It "every user-specific catalog var has a User-scope DSC entry" {
      $dscVars = Get-DscEnvVarNameList -DscPath $UserDscFile
      $userSpecificVars = @($script:Manifest | Where-Object { $_.userSpecific -and $_.hasWindowsEntry } | ForEach-Object { $_.name })

      $missing = $userSpecificVars | Where-Object { $_ -notin $dscVars }
      if ($missing.Count -gt 0) {
        Write-Warning "Missing User-scope DSC env vars: $($missing -join ', ')"
      }
      $missing.Count | Should -Be 0 -Because "every user-specific catalog var expected on Windows should have a User-scope DSC Environment resource"
    }

    It "every User-scope DSC Env resource has a Nix catalog counterpart" {
      $dscVars = Get-DscEnvVarNameList -DscPath $UserDscFile
      $catalogNames = $script:Manifest | ForEach-Object { $_.name }

      $extra = $dscVars | Where-Object { $_ -notin $catalogNames }
      if ($extra.Count -gt 0) {
        Write-Warning "User-scope DSC env vars without Nix catalog entry: $($extra -join ', ')"
      }
      $extra.Count | Should -Be 0 -Because "every DSC Environment resource should have a Nix catalog counterpart"
    }
  }

  Context "DSC parity — machine scope" {
    It "system/env.dsc.yml exists and is readable" {
      $SystemDscFile | Should -Exist
    }

    It "every non-user-specific catalog var has a Machine-scope DSC entry" {
      $dscVars = Get-DscEnvVarNameList -DscPath $SystemDscFile
      $machineSpecificVars = @($script:Manifest | Where-Object { -not $_.userSpecific -and $_.hasWindowsEntry } | ForEach-Object { $_.name })

      $missing = $machineSpecificVars | Where-Object { $_ -notin $dscVars }
      if ($missing.Count -gt 0) {
        Write-Warning "Missing Machine-scope DSC env vars: $($missing -join ', ')"
      }
      $missing.Count | Should -Be 0 -Because "every non-user-specific catalog var expected on Windows should have a Machine-scope DSC Environment resource"
    }

    It "every Machine-scope DSC Env resource has a Nix catalog counterpart" {
      $dscVars = Get-DscEnvVarNameList -DscPath $SystemDscFile
      $catalogNames = $script:Manifest | ForEach-Object { $_.name }

      $extra = $dscVars | Where-Object { $_ -notin $catalogNames }
      if ($extra.Count -gt 0) {
        Write-Warning "Machine-scope DSC env vars without Nix catalog entry: $($extra -join ', ')"
      }
      $extra.Count | Should -Be 0 -Because "every DSC Environment resource should have a Nix catalog counterpart"
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
      $dscVars = Get-DscEnvVarNameList -DscPath $SystemDscFile
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
