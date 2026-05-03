<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Applies the WinGet DSC configuration and then delegates secrets and wallpaper
  provisioning to modular helper scripts under src/modules/windows.

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
  Ordered list of WinGet DSC files applied after secrets/wallpapers are materialized.
  Defaults to user.dsc.yml.

.PARAMETER PreProvisionConfigFiles
  Ordered list of WinGet DSC files applied before secrets/wallpapers are materialized.
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

Import-NucleusWindowsModules -Path ((Resolve-Path -Path $ModuleDir).Path)

$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path

$gpgExe = Resolve-NucleusExecutable -Name "gpg" -CandidatePaths @(
  (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "GnuPG\bin\gpg.exe"),
  (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\gpg.exe"),
  (Join-Path -Path $env:ProgramFiles -ChildPath "GnuPG\bin\gpg.exe")
)

$sopsExe = Resolve-NucleusExecutable -Name "sops" -CandidatePaths @(
  (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Links\sops.exe"),
  (Join-Path -Path $env:ProgramFiles -ChildPath "sops\sops.exe")
)

$hostKeyPath = Join-Path -Path $env:PROGRAMDATA -ChildPath "ssh\ssh_host_ed25519_key"
$script:activeWallpaperPath = $null

$steps = @(
  @{
    Name = "Apply pre-provision WinGet DSC manifests"
    Action = {
      foreach ($configFile in $PreProvisionConfigFiles) {
        $configPath = Join-Path -Path $resolvedConfigDir -ChildPath $configFile
        Invoke-NucleusWingetConfiguration -ConfigPath $configPath
      }
    }
  },
  @{
    Name = "Materialize secrets"
    Action = {
      Sync-NucleusSecrets -SecretsDir $SecretsDir -GpgExe $gpgExe -HostKeyPath $hostKeyPath -SopsExe $sopsExe
    }
  },
  @{
    Name = "Materialize wallpapers"
    Action = {
      $script:activeWallpaperPath = Sync-NucleusWallpapers -AssetsDir $AssetsDir -GpgExe $gpgExe -HostKeyPath $hostKeyPath -OutputDir (Join-Path -Path $HOME -ChildPath "Pictures\wallpapers") -SopsExe $sopsExe
    }
  },
  @{
    Name = "Apply post-provision WinGet DSC manifests"
    Action = {
      foreach ($configFile in $PostProvisionConfigFiles) {
        $configPath = Join-Path -Path $resolvedConfigDir -ChildPath $configFile
        Invoke-NucleusWingetConfiguration -ConfigPath $configPath -WallpaperPath $script:activeWallpaperPath
      }
    }
  }
)

foreach ($step in $steps) {
  Write-Host "==> $($step.Name)" -ForegroundColor Green
  & $step.Action
}
