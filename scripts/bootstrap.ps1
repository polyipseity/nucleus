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
  <#
  .SYNOPSIS
    Returns a required string value from a parsed settings dictionary.

  .DESCRIPTION
    Looks up $Key in $Settings and returns its value as a trimmed string.
    Throws a descriptive error if the key is absent or its value is blank,
    preventing silent failures when a version pin is missing from the
    bootstrap-versions.env file.

  .PARAMETER Settings
    An IDictionary (typically ordered hashtable) returned by
    Import-BootstrapVersions.

  .PARAMETER Key
    The settings key to look up (e.g. 'NUCLEUS_GIT_VERSION').

  .OUTPUTS
    [string]  The non-empty value associated with $Key.
  #>
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
  <#
  .SYNOPSIS
    Parses a shell-compatible KEY=value env file into an ordered hashtable.

  .DESCRIPTION
    Reads $FilePath line by line and extracts KEY=value pairs using the
    pattern ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$.  Comment lines (starting with
    #) and blank lines are silently skipped.  Values wrapped in single or
    double quotes have the outer quotes stripped.  Keys retain their original
    casing.

  .PARAMETER FilePath
    Absolute or relative path to the bootstrap-versions.env file.

  .OUTPUTS
    [ordered hashtable]  Parsed key/value pairs in file order.
  #>
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
  <#
  .SYNOPSIS
    Installs or verifies a winget package at an optional pinned version.

  .DESCRIPTION
    Runs `winget install` with non-interactive flags.  Handles two outcomes
    gracefully without throwing:
      - Exit code 0: package was installed or upgraded successfully.
      - Exit code -1978335189 (WINGET_ERROR_NO_APPLICABLE_UPDATE): package is
        already at the requested version or no applicable upgrade exists.

    When $Version is provided the function first attempts an exact-version
    install.  If that fails with any code other than the above two, it falls
    back to installing the latest available version.  This lets version pins
    work correctly while degrading gracefully when a specific version is
    withdrawn from the WinGet source.

  .PARAMETER Id
    WinGet package identifier (e.g. 'Git.Git').

  .PARAMETER Version
    Optional.  Exact version string to install.  When omitted, the latest
    available version is installed.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Id,

    [Parameter()]
    [string]$Version
  )

  # winget returns this code when the package is already installed and no newer
  # version is available from configured sources.
  $NoApplicableUpgradeExitCode = -1978335189

  $installArgs = @(
    "install"
    "--accept-package-agreements"
    "--accept-source-agreements"
    "--disable-interactivity"
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

    if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
      Write-Host "Package '$Id' is already installed at the requested version (or newer available version is not applicable)." -ForegroundColor Green
      return
    }

    Write-Host "Requested version '$Version' for '$Id' not available. Falling back to latest." -ForegroundColor Yellow
  }

  & winget @installArgs

  if ($LASTEXITCODE -eq 0) {
    return
  }

  if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
    Write-Host "Package '$Id' is already installed and up to date." -ForegroundColor Green
    return
  }

  throw "Failed to install package '$Id' with winget. Exit code: $LASTEXITCODE"
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
