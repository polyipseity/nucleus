<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Applies the Windows configuration through a symmetrical 4-stage lifecycle:
  1) Pre-flight checks
  2) Secret materialization
  3) Primary apply (WinGet DSC)
  4) Post-apply triggers
  Runtime logic delegates to modular helper scripts under src/modules/windows.

.PARAMETER AssetsDir
  Path to the directory containing encrypted wallpaper blobs (*.sops).
  Defaults to src/assets/wallpapers.

.PARAMETER ConfigDir
  Directory containing modular WinGet DSC YAML files.
  Defaults to src/hosts/windows.

.PARAMETER Help
  Show this help message and exit.

.PARAMETER ModuleDir
  Path to the directory containing Windows helper modules (*.ps1).
  Defaults to src/modules/windows.

.PARAMETER PostProvisionConfigFiles
  Ordered list of WinGet DSC files applied by the primary declarative engine.
  Defaults to user.dsc.yml.

.PARAMETER PreProvisionConfigFiles
  Ordered list of WinGet DSC files applied by the primary declarative engine.
  Defaults to system.dsc.yml.

.PARAMETER SecretsDir
  Path to the directory containing SOPS-encrypted .yml secret files.
  Defaults to src/secrets.

.EXAMPLE
  .\src\hosts\windows\apply.ps1
  Apply the full Windows configuration.

.EXAMPLE
  .\src\hosts\windows\apply.ps1 -Help
  Show this help message.
#>
[CmdletBinding()]
param(
  [Parameter()]
  [string]$AssetsDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\assets\wallpapers"),

  [Parameter()]
  [string]$ConfigDir = $PSScriptRoot,

  [Alias("h")]
  [Parameter()]
  [switch]$Help,

  [Parameter()]
  [string]$ModuleDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\modules\windows"),

  [Parameter()]
  [string[]]$PostProvisionConfigFiles = @("user.dsc.yml"),

  [Parameter()]
  [string[]]$PreProvisionConfigFiles = @("system.dsc.yml"),

  [Parameter()]
  [string]$SecretsDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets")
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$script:activeWallpaperPath = $null
$script:gpgExe = $null
$script:hostKeyPath = $null
$script:resolvedPrimaryConfigPaths = @()
$script:sopsExe = $null

function Import-NucleusWindowsModules {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -Path $Path)) {
    throw "Windows modules directory not found: $Path"
  }

  $moduleFiles = @(Get-ChildItem -Path $Path -Filter "*.ps1" -File | Sort-Object Name)
  if ($moduleFiles.Count -eq 0) {
    throw "No Windows modules found in: $Path"
  }

  foreach ($moduleFile in $moduleFiles) {
    Write-Host "Loading module: $($moduleFile.Name)" -ForegroundColor Cyan
    . $moduleFile.FullName
  }

  $requiredFunctions = @(
    "Invoke-NucleusWingetConfiguration",
    "Resolve-NucleusExecutable",
    "Sync-NucleusSecrets",
    "Sync-NucleusWallpapers"
  )

  foreach ($requiredFunction in $requiredFunctions) {
    if (-not (Get-Command -Name $requiredFunction -CommandType Function -ErrorAction SilentlyContinue)) {
      throw "Required function was not loaded from Windows modules: $requiredFunction"
    }
  }
}

function Write-NucleusStageHeader {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Number,

    [Parameter(Mandatory = $true)]
    [string]$Title
  )

  Write-Host "==> [Stage $Number/4] $Title" -ForegroundColor Green
}

function Invoke-NucleusPreFlightChecks {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$ConfigDir,

    [Parameter(Mandatory = $true)]
    [string]$ModuleDir,

    [Parameter(Mandatory = $true)]
    [string[]]$PostProvisionConfigFiles,

    [Parameter(Mandatory = $true)]
    [string[]]$PreProvisionConfigFiles,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir
  )

  if (-not (Get-Command -Name "winget" -ErrorAction SilentlyContinue)) {
    throw "Required command 'winget' is not available."
  }

  Import-NucleusWindowsModules -Path ((Resolve-Path -Path $ModuleDir).Path)

  $resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
  $script:resolvedPrimaryConfigPaths = @()

  foreach ($configFile in @($PreProvisionConfigFiles + $PostProvisionConfigFiles)) {
    $configPath = Join-Path -Path $resolvedConfigDir -ChildPath $configFile
    if (-not (Test-Path -Path $configPath)) {
      throw "WinGet DSC configuration not found: $configPath"
    }

    $script:resolvedPrimaryConfigPaths += (Resolve-Path -Path $configPath).Path
  }

  if ($script:resolvedPrimaryConfigPaths.Count -eq 0) {
    throw "No WinGet DSC configuration files were provided to apply."
  }

  $script:gpgExe = Resolve-NucleusExecutable -Name "gpg" -CandidatePaths @(
    (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "GnuPG\bin\gpg.exe"),
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\gpg.exe"),
    (Join-Path -Path $env:ProgramFiles -ChildPath "GnuPG\bin\gpg.exe")
  )

  $script:sopsExe = Resolve-NucleusExecutable -Name "sops" -CandidatePaths @(
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\sops.exe"),
    (Join-Path -Path $env:ProgramFiles -ChildPath "sops\sops.exe")
  )

  $script:hostKeyPath = Join-Path -Path $env:PROGRAMDATA -ChildPath "ssh\ssh_host_ed25519_key"

  Write-Host "Targeted WinGet DSC manifests:" -ForegroundColor Cyan
  foreach ($configPath in $script:resolvedPrimaryConfigPaths) {
    Write-Host "  - $configPath" -ForegroundColor Cyan
  }

  Write-Host "Targeted secrets directory: $SecretsDir" -ForegroundColor Cyan
  Write-Host "Targeted wallpaper assets: $AssetsDir" -ForegroundColor Cyan
}

function Invoke-NucleusSecretMaterialization {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir
  )

  Sync-NucleusSecrets -SecretsDir $SecretsDir -GpgExe $script:gpgExe -HostKeyPath $script:hostKeyPath -SopsExe $script:sopsExe

  $script:activeWallpaperPath = Sync-NucleusWallpapers -AssetsDir $AssetsDir -GpgExe $script:gpgExe -HostKeyPath $script:hostKeyPath -OutputDir (Join-Path -Path $HOME -ChildPath "Pictures\wallpapers") -SopsExe $script:sopsExe
}

function Invoke-NucleusPrimaryApply {
  foreach ($configPath in $script:resolvedPrimaryConfigPaths) {
    Invoke-NucleusWingetConfiguration -ConfigPath $configPath -WallpaperPath $script:activeWallpaperPath
  }
}

function Invoke-NucleusPostApplyTriggers {
  if (-not [string]::IsNullOrWhiteSpace($script:activeWallpaperPath) -and (Test-Path -Path $script:activeWallpaperPath)) {
    Write-Host "Refreshing desktop wallpaper from materialized asset." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $script:activeWallpaperPath
    & (Join-Path -Path $env:SystemRoot -ChildPath "System32\rundll32.exe") "user32.dll,UpdatePerUserSystemParameters" | Out-Null
  }

  Write-Host "Post-apply trigger: open a new PowerShell session to pick up refreshed environment variables." -ForegroundColor Green
}

Write-NucleusStageHeader -Number 1 -Title "Pre-flight checks"
Invoke-NucleusPreFlightChecks -AssetsDir $AssetsDir -ConfigDir $ConfigDir -ModuleDir $ModuleDir -PostProvisionConfigFiles $PostProvisionConfigFiles -PreProvisionConfigFiles $PreProvisionConfigFiles -SecretsDir $SecretsDir

Write-NucleusStageHeader -Number 2 -Title "Secret materialization"
Invoke-NucleusSecretMaterialization -AssetsDir $AssetsDir -SecretsDir $SecretsDir

Write-NucleusStageHeader -Number 3 -Title "Primary apply"
Invoke-NucleusPrimaryApply

Write-NucleusStageHeader -Number 4 -Title "Post-apply triggers"
Invoke-NucleusPostApplyTriggers
