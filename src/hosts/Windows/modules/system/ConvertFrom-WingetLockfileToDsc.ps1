<#
.SYNOPSIS
  Generate a locked DSC YAML by merging version pins from lockfile.json into a WinGet DSC file.

.DESCRIPTION
  Reads the lockfile.json winget section and the source WinGet DSC YAML,
  injects `version` fields into each Microsoft.WinGet.Client/Package resource
  whose settings.id and source: winget match a lockfile entry.
  Packages not in the lockfile are left unmodified.

  When the lockfile is missing or has no winget section, the source DSC is
  copied verbatim (graceful degradation).

.PARAMETER ConfigPath
  Path to the base WinGet DSC YAML (e.g. dsc.yml or packages.dsc.yml in the system/ directory).

.PARAMETER LockfilePath
  Path to lockfile.json.

.PARAMETER OutputPath
  Path to write the locked DSC.

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\settings.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\settings.locked.dsc.yml

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\registry.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\registry.locked.dsc.yml

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\packages.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\packages.locked.dsc.yml

.NOTES
  Environment variables:
    (none)    No environment variables used.
#>
function ConvertFrom-WingetLockfileToDsc {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$LockfilePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
  )

  # Graceful degradation: missing or unparseable lockfile → passthrough.
  $wingetVersions = @{}
  if (Test-Path $LockfilePath) {
    try {
      $lockfile = Get-Content -Path $LockfilePath -Raw | ConvertFrom-Json -AsHashtable
      if ($lockfile.ContainsKey('winget') -and $lockfile['winget']) {
        $wingetVersions = $lockfile['winget']
      }
    } catch {
      Write-Warning "ConvertFrom-WingetLockfileToDsc: lockfile parse failed, copying config as-is"
    }
  } else {
    Write-Warning "ConvertFrom-WingetLockfileToDsc: lockfile not found at $LockfilePath, copying config as-is"
  }

  if (-not (Test-Path -Path $ConfigPath)) {
    throw "ConvertFrom-WingetLockfileToDsc: source DSC not found at $ConfigPath"
  }

  $lines = Get-Content -Path $ConfigPath
  $outputLines = [System.Collections.ArrayList]::new()
  $currentWingetId = $null

  foreach ($line in $lines) {
    # Reset tracking at resource boundary (4-space indent).
    if ($line -match '^    - resource:') {
      $currentWingetId = $null
    }

    # Capture settings-level id (8-space indent).
    if ($line -match '^        id:\s+(.+)$') {
      $currentWingetId = $Matches[1]
    }

    # Emit the current line.
    # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments -- [void] intentional; Add returns collection count, discarded
    [void]$outputLines.Add($line)

    # After source: winget at 8-space indent, inject version if lockfile has one.
    if ($line -match '^        source:\s+winget$' -and $currentWingetId) {
      if ($wingetVersions.ContainsKey($currentWingetId)) {
        $version = $wingetVersions[$currentWingetId]
        if ($version) {
          # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments -- [void] intentional; Add returns collection count, discarded
          [void]$outputLines.Add("        version: $version")
        }
      }
    }
  }

  $outputLines -join "`n" | Out-File -FilePath $OutputPath -Encoding utf8 -NoNewline
  Write-Output "ConvertFrom-WingetLockfileToDsc: wrote $OutputPath"
}
