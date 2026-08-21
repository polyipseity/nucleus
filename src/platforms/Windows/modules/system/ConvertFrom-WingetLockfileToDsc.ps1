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

.PARAMETER EnabledPackages
  Optional hashset of WinGet package IDs that are enabled. When provided, any
  Microsoft.WinGet.Client/Package resource whose settings.id is NOT in this set
  is dropped from the output. This enforces the single-source overlap enable
  flag (managedPackages in core.nix) on Windows, which does not run Nix.
  When omitted, all resources are emitted (no filtering).

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\scheduler.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\scheduler.locked.dsc.yml

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\firewall.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\firewall.locked.dsc.yml

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\packages.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\packages.locked.dsc.yml

.EXAMPLE
  ConvertFrom-WingetLockfileToDsc -ConfigPath .\system\packages.dsc.yml -LockfilePath ..\..\lockfiles\lockfile.json -OutputPath .\system\packages.locked.dsc.yml -EnabledPackages @{ 'Anysphere.Cursor' = $true; 'OBSProject.OBSStudio.Pre-release' = $true }

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
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [hashtable]$EnabledPackages
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
      Write-NucleusWarning -CommandName 'ConvertFrom-WingetLockfileToDsc' "lockfile parse failed, copying config as-is"
    }
  } else {
    Write-NucleusWarning -CommandName 'ConvertFrom-WingetLockfileToDsc' "lockfile not found at $LockfilePath, copying config as-is"
  }

  if (-not (Test-Path -Path $ConfigPath)) {
    throw "ConvertFrom-WingetLockfileToDsc: source DSC not found at $ConfigPath"
  }

  $filterEnabled = $PSBoundParameters.ContainsKey('EnabledPackages') -and $EnabledPackages
  $lines = Get-Content -Path $ConfigPath
  $outputLines = [System.Collections.ArrayList]::new()
  # Buffer the current resource block so it can be dropped wholesale when disabled.
  $resourceBuffer = [System.Collections.ArrayList]::new()
  $inResource = $false
  $currentWingetId = $null

  foreach ($line in $lines) {
    # Resource boundary (4-space indent) starts a new block.
    if ($line -match '^    - resource:') {
      # Flush the previous buffered resource (if any) before starting a new one.
      if ($inResource) {
        if (-not $filterEnabled -or ($currentWingetId -and $EnabledPackages.ContainsKey($currentWingetId))) {
          foreach ($buffered in $resourceBuffer) {
            [void]$outputLines.Add($buffered)  # check-suppress:suppression_doc: Add returns collection count, discarded
          }
        }
      }
      $resourceBuffer = [System.Collections.ArrayList]::new()
      $inResource = $true
      $currentWingetId = $null
      [void]$resourceBuffer.Add($line)  # check-suppress:suppression_doc: Add returns collection count, discarded
      continue
    }

    if ($inResource) {
      [void]$resourceBuffer.Add($line)  # check-suppress:suppression_doc: Add returns collection count, discarded
      # Capture settings-level id (8-space indent).
      if ($line -match '^        id:\s+(.+)$') {
        $currentWingetId = $Matches[1]
      }
      # After source: winget at 8-space indent, inject version if lockfile has one.
      if ($line -match '^        source:\s+winget$' -and $currentWingetId) {
        if ($wingetVersions.ContainsKey($currentWingetId)) {
          $version = $wingetVersions[$currentWingetId]
          if ($version) {
            [void]$resourceBuffer.Add("        version: $version")  # check-suppress:suppression_doc: Add returns collection count, discarded
          }
        }
      }
      continue
    }

    # Lines outside any resource are emitted verbatim.
    [void]$outputLines.Add($line)  # check-suppress:suppression_doc: Add returns collection count, discarded
  }

  # Flush the final buffered resource.
  if ($inResource) {
    if (-not $filterEnabled -or ($currentWingetId -and $EnabledPackages.ContainsKey($currentWingetId))) {
      foreach ($buffered in $resourceBuffer) {
        [void]$outputLines.Add($buffered)  # check-suppress:suppression_doc: Add returns collection count, discarded
      }
    }
  }

  $outputLines -join "`n" | Out-File -FilePath $OutputPath -Encoding utf8 -NoNewline
  Write-NucleusInfo -CommandName 'ConvertFrom-WingetLockfileToDsc' "wrote $OutputPath"
}
