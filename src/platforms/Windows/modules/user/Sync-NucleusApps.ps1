<#
.SYNOPSIS
  Deploys nucleus-* command shims to the managed PATH.

.DESCRIPTION
  Reads src/modules/completions/nucleus-apps.json and writes
  %USERPROFILE%\.local\bin\nucleus-<name>.cmd for every command that has a
  scripts/<name>.ps1 twin. Each shim dispatches to the repository script with
  the repo root resolved from %NUCLEUS_REPO_ROOT% at runtime.

  Commands without a scripts/<name>.ps1 twin are skipped by file presence, not
  by a hand-kept list.

.PARAMETER Enabled
  Whether nucleus app shim deployment should be enforced. When false, removes
  only shims this function owns.

.PARAMETER RepoRoot
  Absolute path to the live repository root.

.PARAMETER UserRoot
  Absolute path to the nucleus Windows USER root (%LOCALAPPDATA%\nucleus).

.PARAMETER UserProfile
  Absolute path to the user profile (%USERPROFILE%).

.NOTES
  Required preload: ManagedPaths.ps1 (Get-NucleusManagedBinDir) and
  Format-NucleusOutput.psm1 (Write-Nucleus*), both dot-sourced by apply.ps1.

  Exit codes: this function does not emit exit codes; failures are reported as
  warnings.
#>

function Sync-NucleusApps {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$UserRoot,

    [Parameter(Mandatory)]
    [string]$UserProfile
  )

  $label = 'nucleus-apps'
  $shimDir = Get-NucleusManagedBinDir -UserProfile $UserProfile
  $manifestPath = Join-Path -Path $RepoRoot -ChildPath 'src\modules\completions\nucleus-apps.json'
  $ownedPrefix = 'nucleus-'

  try {
    if (-not (Test-Path -LiteralPath $shimDir)) {
      New-Item -ItemType Directory -Path $shimDir -Force > $null
    }

    $ownedCommands = @()
    if (Test-Path -LiteralPath $manifestPath) {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
      foreach ($name in @($manifest.commands)) {
        $scriptPath = Join-Path -Path $RepoRoot -ChildPath "scripts\$name.ps1"
        if (Test-Path -LiteralPath $scriptPath) {
          $ownedCommands += $name
        }
      }
    } else {
      Write-NucleusWarning -Message "[$label] manifest not found: $manifestPath"
    }

    if (-not $Enabled) {
      foreach ($name in $ownedCommands) {
        $shimPath = Join-Path -Path $shimDir -ChildPath "$ownedPrefix$name.cmd"
        if (Test-Path -LiteralPath $shimPath) {
          Remove-Item -LiteralPath $shimPath -Force
          Write-NucleusNotice -Message "[$label] removed $shimPath"
        }
      }
      return
    }

    foreach ($name in $ownedCommands) {
      $shimPath = Join-Path -Path $shimDir -ChildPath "$ownedPrefix$name.cmd"
      $content = "@echo off`r`npwsh -NoProfile -File `"%NUCLEUS_REPO_ROOT%\scripts\$name.ps1`" %*`r`n"
      $current = $null
      if (Test-Path -LiteralPath $shimPath) {
        $current = Get-Content -LiteralPath $shimPath -Raw
      }
      if ($current -ne $content) {
        Set-Content -LiteralPath $shimPath -Value $content -NoNewline -Force
        Write-NucleusNotice -Message "[$label] wrote $shimPath"
      }
    }

    # Remove stale shims this function owns for commands no longer present.
    Get-ChildItem -LiteralPath $shimDir -Filter "$ownedPrefix*.cmd" -File -ErrorAction SilentlyContinue | # check-suppress:suppression_doc: missing or unreadable shim entries must not abort stale-shim cleanup
      Where-Object {
        $_.Name -match '^nucleus-(.+)\.cmd$' -and $Matches[1] -notin $ownedCommands
      } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-NucleusNotice -Message "[$label] removed stale $($_.FullName)"
      }
  } catch {
    Write-NucleusWarning -Message "[$label] failed: $($_.Exception.Message)"
  }
}
