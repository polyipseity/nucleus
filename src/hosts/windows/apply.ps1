<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Orchestrates the Windows configuration lifecycle in a single script:
    1. Load helper functions from $ModuleDir (common, secrets, wallpapers).
    2. Materialize primary-user secrets from src/secrets via SOPS.
    3. Materialize wallpaper blobs and remove stale decrypted files.
    4. Resolve each DSC config file relative to $ConfigDir.
    5. Pass each file to Invoke-NucleusWingetConfiguration, which substitutes
       the __NUCLEUS_ACTIVE_WALLPAPER__ token (when present) and runs
       `winget configure`.
  The script is idempotent: re-running it re-applies all DSC resources and
  converges any drift from the desired state.

.PARAMETER ConfigDir
  Directory that contains the DSC YAML files.  Defaults to the directory
  containing this script ($PSScriptRoot).

.PARAMETER ConfigFiles
  Ordered list of DSC YAML filenames to apply.  Defaults to
  @('system.dsc.yml', 'user.dsc.yml').  Filenames are resolved relative to
  $ConfigDir.

.PARAMETER ModuleDir
  Path to the directory containing common.ps1 and other Windows module
  helpers.  Defaults to ..\..\modules\windows relative to $PSScriptRoot.

.PARAMETER PrimaryUsername
  Username allowed to materialize user-scoped secrets. Defaults to the
  current interactive user.

.PARAMETER Help
  When present, prints this help text and exits without applying anything.

.EXAMPLE
  # Apply with defaults (both DSC files, from the script's own directory):
  .\apply.ps1

.EXAMPLE
  # Apply only the user-level DSC file:
  .\apply.ps1 -ConfigFiles @('user.dsc.yml')

.EXAMPLE
  # Apply while explicitly scoping secret materialization to one user:
  .\apply.ps1 -PrimaryUsername 'polyipseity'
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = $PSScriptRoot,
  [string[]]$ConfigFiles = @("system.dsc.yml", "user.dsc.yml"),
  [switch]$Help,
  [string]$ModuleDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\modules\windows"),
  [string]$PrimaryUsername = [System.Environment]::UserName
)

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
. (Join-Path -Path $resolvedModuleDir -ChildPath "common.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "secrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "wallpapers.ps1")

$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
$hostKeyPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key"

# Resolve managed executables before running any decryption/materialization.
$sopsPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Packages\SecretsOPerationS.SOPS_*") -Directory -ErrorAction SilentlyContinue |
  Sort-Object -Property Name -Descending |
  Select-Object -First 1

$sopsExecutableFromWinget = $null
if ($null -ne $sopsPackageDir) {
  $sopsExecutableFromWinget = Join-Path -Path $sopsPackageDir.FullName -ChildPath "sops.exe"
}

$sopsCandidates = @(
  $sopsExecutableFromWinget,
  (Get-Command -Name "sops.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$gpgCandidates = @(
  (Join-Path -Path $env:ProgramFiles -ChildPath "GnuPG\bin\gpg.exe"),
  (Get-Command -Name "gpg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$sopsExe = Resolve-NucleusExecutable -Name "sops" -CandidatePaths $sopsCandidates
$gpgExe = Resolve-NucleusExecutable -Name "gpg" -CandidatePaths $gpgCandidates

# Materialize user-scoped secrets once before DSC resources run.
$secretsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets"
Sync-NucleusSecrets -SecretsDir $secretsDir -GpgExe $gpgExe -HostKeyPath $hostKeyPath -PrimaryUsername $PrimaryUsername -SopsExe $sopsExe

# Materialize decrypted wallpapers ahead of DSC so user.dsc.yml can resolve an
# explicit active wallpaper path deterministically.
$wallpaperAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\assets\wallpapers"
$wallpaperOutputDir = Join-Path -Path $HOME -ChildPath "Pictures\wallpapers"
$activeWallpaperPath = Sync-NucleusWallpapers -AssetsDir $wallpaperAssetsDir -GpgExe $gpgExe -HostKeyPath $hostKeyPath -OutputDir $wallpaperOutputDir -SopsExe $sopsExe
Remove-NucleusStaleWallpapers -AssetsDir $wallpaperAssetsDir -OutputDir $wallpaperOutputDir

foreach ($configFile in $ConfigFiles) {
  Invoke-NucleusWingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile) -WallpaperPath $activeWallpaperPath
}
