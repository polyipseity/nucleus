<#
.SYNOPSIS
  Apply the nucleus configuration for Windows.

.DESCRIPTION
  Orchestrates the Windows configuration lifecycle in a single script:
    1. Load helper functions from $ModuleDir one-function module files.
    2. Materialize primary-user secrets from src/secrets via SOPS.
    3. Materialize wallpaper blobs and remove stale decrypted files.
    4. Resolve each DSC config file relative to $ConfigDir.
    5. Pass each file to Invoke-NucleusWingetConfiguration, which substitutes
       the __NUCLEUS_ACTIVE_WALLPAPER__ token (when present) and runs
       `winget configure`.
    6. Converge user-level shell/editor/Git/SSH parity state.
    7. Converge remote-access and power posture parity state.
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
  Path to the directory containing one-function Windows helper modules.
  Defaults to ..\..\modules\windows relative to $PSScriptRoot.

.PARAMETER PrimaryUsername
  Username allowed to materialize user-scoped secrets. Defaults to the
  current interactive user.

.PARAMETER EnableSecretsParity
  Enable managed secret materialization and managed SSH key cleanup fallback.

.PARAMETER EnableGitSshParity
  Enable managed user-level Git/SSH parity convergence and block cleanup logic.

.PARAMETER EnablePowerParity
  Enable managed Windows power policy parity convergence and cleanup fallback.

.PARAMETER EnableRemoteAccessParity
  Enable managed OpenSSH remote-access convergence and cleanup fallback.

.PARAMETER EnableShellParity
  Enable managed PowerShell profile parity block and cleanup fallback.

.PARAMETER EnableVsCodeExtensionsParity
  Enable managed VS Code extension parity convergence and cleanup fallback.

.PARAMETER EnableVsCodeSettingsParity
  Enable managed VS Code settings parity convergence and managed-key cleanup.

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

.EXAMPLE
  # Apply while disabling managed VS Code settings parity (cleanup only):
  .\apply.ps1 -EnableVsCodeSettingsParity:$false

.EXAMPLE
  # Apply while disabling managed remote-access parity (cleanup only):
  .\apply.ps1 -EnableRemoteAccessParity:$false
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = $PSScriptRoot,
  [string[]]$ConfigFiles = @("system.dsc.yml", "user.dsc.yml"),
  [switch]$Help,
  [string]$ModuleDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\..\modules\windows"),
  [string]$PrimaryUsername = [System.Environment]::UserName,
  [bool]$EnableSecretsParity = $true,
  [bool]$EnableGitSshParity = $true,
  [bool]$EnablePowerParity = $true,
  [bool]$EnableRemoteAccessParity = $true,
  [bool]$EnableShellParity = $true,
  [bool]$EnableVsCodeExtensionsParity = $true,
  [bool]$EnableVsCodeSettingsParity = $true
)

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
. (Join-Path -Path $resolvedModuleDir -ChildPath "get-nucleusdecryptedblob.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "get-nucleussecrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "git-ssh.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "invoke-nucleusjitsecretmaterialization.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "invoke-nucleuswingetconfiguration.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "power.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "remote-access.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-nucleusmanagedsecrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "remove-nucleusstalewallpapers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "resolve-nucleusexecutable.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "shell.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleussecretfile.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleussecrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleusvscodeextensions.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleusvscodesettings.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleuswallpapers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "test-nucleusprimaryuser.ps1")

$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
$machineSshHostKeyPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key"
$primarySshKeyPath = Join-Path -Path $HOME -ChildPath ".ssh\ssh_personal_$PrimaryUsername"

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
if ($EnableSecretsParity) {
  Sync-NucleusSecrets -SecretsDir $secretsDir -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -PrimaryUsername $PrimaryUsername -SopsExe $sopsExe
}
else {
  Remove-NucleusManagedSecrets -PrimaryUsername $PrimaryUsername
}

# Materialize decrypted wallpapers ahead of DSC so user.dsc.yml can resolve an
# explicit active wallpaper path deterministically.
$wallpaperAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\assets\wallpapers"
$wallpaperOutputDir = Join-Path -Path $HOME -ChildPath "Pictures\wallpapers"
$activeWallpaperPath = Sync-NucleusWallpapers -AssetsDir $wallpaperAssetsDir -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -OutputDir $wallpaperOutputDir -SopsExe $sopsExe
Remove-NucleusStaleWallpapers -AssetsDir $wallpaperAssetsDir -OutputDir $wallpaperOutputDir

foreach ($configFile in $ConfigFiles) {
  Invoke-NucleusWingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile) -WallpaperPath $activeWallpaperPath
}

Sync-NucleusVsCodeSettings -Enabled:$EnableVsCodeSettingsParity
Sync-NucleusVsCodeExtensions -Enabled:$EnableVsCodeExtensionsParity
Sync-NucleusGitAndSshConfig -Enabled:$EnableGitSshParity -PrimaryUsername $PrimaryUsername
Sync-NucleusShellProfile -Enabled:$EnableShellParity
Sync-NucleusOpenSshServer -Enabled:$EnableRemoteAccessParity
Sync-NucleusPowerPolicy -Enabled:$EnablePowerParity
