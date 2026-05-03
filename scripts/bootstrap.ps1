<#
.SYNOPSIS
  Install bootstrap dependencies for the nucleus environment on Windows.

.DESCRIPTION
  Installs Git, GnuPG, and SOPS via winget using pinned versions from
  scripts/bootstrap-versions.env.
  Use -Apply to run the Windows apply script after dependency installation.

.PARAMETER Apply
  Install dependencies, then run src/hosts/windows/apply.ps1.

.PARAMETER ApplyArgs
  Optional arguments passed through to src/hosts/windows/apply.ps1.

.PARAMETER Help
  Show this help message and exit.

.EXAMPLE
  .\bootstrap.ps1
  Install bootstrap dependencies only.

.EXAMPLE
  .\bootstrap.ps1 -Apply
  Install dependencies, then run the apply flow.

.EXAMPLE
  .\bootstrap.ps1 -Apply -ApplyArgs -Help
  Install dependencies, then show help for the apply script.
#>
[CmdletBinding()]
param(
  [Alias("a")]
  [Parameter()]
  [switch]$Apply,

  [Parameter()]
  [string[]]$ApplyArgs,

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$VersionsFilePath = Join-Path -Path $PSScriptRoot -ChildPath "bootstrap-versions.env"

function Get-RequiredVersionSetting {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Settings,

    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  if (-not $Settings.Contains($Key) -or [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) {
    throw "Missing required setting '$Key' in $VersionsFilePath."
  }

  return [string]$Settings[$Key]
}

function Import-BootstrapVersions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
  )

  if (-not (Test-Path -Path $FilePath)) {
    throw "Bootstrap versions file not found: $FilePath"
  }

  $settings = [ordered]@{}

  foreach ($line in Get-Content -Path $FilePath) {
    $trimmed = $line.Trim()

    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed -notmatch "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$") {
      continue
    }

    $key = $Matches[1]
    $value = $Matches[2].Trim()

    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $settings[$key] = $value
  }

  return $settings
}

function Ensure-WingetPackage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Id,

    [Parameter()]
    [string]$Version
  )

  $installArgs = @(
    "install"
    "--accept-package-agreements"
    "--accept-source-agreements"
    "--exact"
    "--id"
    $Id
    "--silent"
  )

  if ($Version) {
    $versionedArgs = @($installArgs + @("--version", $Version))
    & winget @versionedArgs

    if ($LASTEXITCODE -eq 0) {
      return
    }

    Write-Host "Requested version '$Version' for '$Id' not available. Falling back to latest." -ForegroundColor Yellow
  }

  & winget @installArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install package '$Id' with winget."
  }
}

if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
  throw "winget is required but was not found in PATH."
}

$BootstrapVersions = Import-BootstrapVersions -FilePath $VersionsFilePath

$BootstrapPackageVersions = [ordered]@{
  "Git.Git" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GIT_VERSION"
  "GnuPG.Gpg4win" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GPG4WIN_VERSION"
  "SecretsOPerationS.SOPS" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_SOPS_VERSION"
}

foreach ($package in $BootstrapPackageVersions.GetEnumerator()) {
  Ensure-WingetPackage -Id $package.Key -Version $package.Value
}

if ($Apply) {
  $applyScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\hosts\windows\apply.ps1"
  if (-not (Test-Path -Path $applyScriptPath)) {
    throw "Apply script not found: $applyScriptPath"
  }

  Write-Host "Running apply flow via $applyScriptPath" -ForegroundColor Cyan
  & $applyScriptPath @ApplyArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Apply script exited with code $LASTEXITCODE."
  }

  return
}

Write-Host "Bootstrap complete. Run '.\src\hosts\windows\apply.ps1' to configure this host, or use -Apply." -ForegroundColor Green
