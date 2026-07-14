<#
.SYNOPSIS
    Regression tests for the Windows apply.ps1 self-elevation mechanism.
.DESCRIPTION
    Verifies that the self-elevation mechanism (hard non-admin guard →
    Start-Process -Verb RunAs → all operations elevated) is intact and
    that no stale admin-fallback patterns remain.  These are static
    analysis tests — they parse apply.ps1 text rather than executing it
    (elevation requires interactive UAC).
.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/hosts/Windows/regression/elevation.Tests.ps1 -Passthru"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")
  $ApplyPs1 = Join-Path $RepoRoot "src\hosts\Windows\apply.ps1"

  function Get-ApplyContent {
    return Get-Content -Raw -Path $ApplyPs1
  }
}

Describe "Self-elevation parameters" {
  It "declares -Elevated switch parameter" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('[switch]$Elevated'))
  }

  It "declares -ParamsJson string parameter" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('[string]$ParamsJson = ""'))
  }
}

Describe "ParamsJson deserialization" {
  It "reads ParamsJson file when -ParamsJson is provided" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('if ($ParamsJson -and (Test-Path $ParamsJson))'))
  }

  It "sets `$Elevated = `$true after deserialization" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('$Elevated = $true'))
  }
}

Describe "Admin guard" {
  It "guards against administrator without -Elevated flag" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('if ($isAdmin -and -not $Elevated)'))
  }

  It "exits with error when run as un-elevated admin" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('"This script must not be run as Administrator.'))
  }
}

Describe "Self-elevation mechanism" {
  It "uses Verb RunAs for Start-Process" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('$psi.Verb = "RunAs"'))
  }

  It "uses UseShellExecute for elevation" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('$psi.UseShellExecute = $true'))
  }

  It "detects UAC cancellation (null process)" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('if ($null -eq $proc)'))
  }

  It "throws descriptive message on UAC cancellation" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('"User cancelled the elevation prompt (UAC).'))
  }

  It "propagates exit code from elevated child process" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('exit $exitCode'))
  }

  It "cleans up temp JSON file in both parent and child paths" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('Remove-Item $paramsJsonPath'))
  }

  It "sets all parameters in the re-invocation hashtable" {
    $content = Get-ApplyContent
    $content | Should -Match ([regex]::Escape('$params = @{'))
    $content | Should -Match ([regex]::Escape('Elevated         = $true'))
  }
}

Describe "No stale admin-fallback patterns remain" {
  It "no Send-NucleusEnvChangeNotification call exists" {
    $content = Get-ApplyContent
    $content | Should -Not -Match ('Send-NucleusEnvChangeNotification')
  }

  It "no two-phase NUCLEUS_HOST promotion comment (Phase 2 cleanup) exists" {
    $content = Get-ApplyContent
    $content | Should -Not -Match ('Phase 2 cleanup|Phase 2 of the two-phase')
  }

  It "no User-scope NUCLEUS_HOST write exists" {
    $content = Get-ApplyContent
    $content | Should -Not -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable("NUCLEUS_HOST", "Windows", "User")'))
  }

  It "no Write-Warning fallback for cannot promote NUCLEUS_REPO_ROOT exists" {
    $content = Get-ApplyContent
    $content | Should -Not -Match ([regex]::Escape('Write-Warning "apply: cannot promote NUCLEUS_REPO_ROOT to Machine scope'))
  }

  It "no Write-Warning fallback for Application Event Log size exists" {
    $content = Get-ApplyContent
    $content | Should -Not -Match ([regex]::Escape('Write-NucleusWarning "Failed to set Application Event Log max size'))
  }
}
