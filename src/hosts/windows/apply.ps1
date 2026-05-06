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

.PARAMETER EnableHostAgeKeyRegistration
  Register this machine's SSH host public key as an age recipient in .sops.yaml
  and rewrap all SOPS-encrypted files on first apply.  Idempotent: no-op when
  the key is already registered.  Disable to skip registration (e.g. on
  machines where the SSH host key is not yet a designated SOPS recipient).

.PARAMETER EnablePowerParity
  Enable managed Windows power policy parity convergence and cleanup fallback.

.PARAMETER EnableRdpParity
  Enable managed Windows built-in RDP convergence and cleanup fallback.

.PARAMETER EnableRemoteAccessParity
  Enable managed OpenSSH remote-access convergence and cleanup fallback.

.PARAMETER EnableShellParity
  Enable managed PowerShell profile parity block and cleanup fallback.

.PARAMETER EnableVsCodeExtensionsParity
  Enable managed VS Code extension parity convergence and cleanup fallback.

.PARAMETER EnableVsCodeSettingsParity
  Enable managed VS Code settings parity convergence and managed-key cleanup.

.PARAMETER MinFreeDiskGB
  Minimum free space threshold (GiB) used by the pre-flight health check.

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
  # Apply while disabling machine age key auto-registration in .sops.yaml:
  .\apply.ps1 -EnableHostAgeKeyRegistration:$false

.EXAMPLE
  # Apply while disabling managed VS Code settings parity (cleanup only):
  .\apply.ps1 -EnableVsCodeSettingsParity:$false

.EXAMPLE
  # Apply while disabling managed remote-access parity (cleanup only):
  .\apply.ps1 -EnableRemoteAccessParity:$false

.EXAMPLE
  # Apply while disabling managed Windows built-in RDP (cleanup only):
  .\apply.ps1 -EnableRdpParity:$false
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
  [bool]$EnableHostAgeKeyRegistration = $true,
  [bool]$EnablePowerParity = $true,
  [bool]$EnableRdpParity = $true,
  [bool]$EnableRemoteAccessParity = $true,
  [bool]$EnableShellParity = $true,
  [bool]$EnableVsCodeExtensionsParity = $true,
  [bool]$EnableVsCodeSettingsParity = $true,
  [int]$MinFreeDiskGB = 10
)

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
. (Join-Path -Path $resolvedModuleDir -ChildPath "convert-sshpublickeytoage.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "get-nucleusdecryptedblob.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "get-nucleussecrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "git-ssh.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "initialize-nucleussshshostkey.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "invoke-nucleusjitsecretmaterialization.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "invoke-nucleussecretverification.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "invoke-nucleuswingetconfiguration.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "power.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "rdp.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "register-nucleushostagekey.ps1")
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
. (Join-Path -Path $resolvedModuleDir -ChildPath "verify-archiving-stack.ps1")

$healthCheckScript = Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\scripts\health-check.ps1"
if (Test-Path -Path $healthCheckScript) {
  & $healthCheckScript -MinFreeGB $MinFreeDiskGB -SkipSecretTooling
}

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

# Define shared path variables before any registration or pre-flight step so
# both Register-NucleusHostAgeKey and the pre-flight loop reference the same
# resolved paths without duplicate definitions later in the script.
$secretsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets"
$wallpaperAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\assets\wallpapers"
$machineSshHostKeyPubPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key.pub"
$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\")).Path
$sopsYamlPath = Join-Path -Path $repoRoot -ChildPath ".sops.yaml"

# Ensure the SSH host key exists before age key registration.  On a fresh
# machine the key is absent until the OpenSSH Server service first starts;
# Initialize-NucleusSshHostKey starts it briefly if the service is installed
# but the key has not yet been written.
if ($EnableHostAgeKeyRegistration) {
  Initialize-NucleusSshHostKey -MachineSshHostKeyPath $machineSshHostKeyPath
}

# Auto-register this machine's age key in .sops.yaml if not already present.
# Must run before the pre-flight secret decryption check so that on the very
# first apply the machine can already decrypt its own SOPS-encrypted secrets.
if ($EnableHostAgeKeyRegistration) {
  Register-NucleusHostAgeKey `
    -MachineSshHostKeyPubPath $machineSshHostKeyPubPath `
    -SopsExe $sopsExe `
    -SopsYamlPath $sopsYamlPath `
    -SecretsDir $secretsDir `
    -WallpaperAssetsDir $wallpaperAssetsDir
}

# Materialize user-scoped secrets once before DSC resources run.
$secretPreflightFiles = @("git-identities.yml", "gpg-personal.yml", "ssh-personal.yml")
foreach ($secretFile in $secretPreflightFiles) {
  $secretPath = Join-Path -Path $secretsDir -ChildPath $secretFile
  if (-not (Test-Path -Path $secretPath)) {
    throw "Required secret file was not found: $secretPath"
  }

  # Fail fast if current machine identities cannot decrypt managed secrets.
  Get-NucleusSecrets -FilePath $secretPath -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe | Out-Null
}

if ($EnableSecretsParity) {
  Sync-NucleusSecrets -SecretsDir $secretsDir -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -PrimaryUsername $PrimaryUsername -SopsExe $sopsExe
}
else {
  Remove-NucleusManagedSecrets -PrimaryUsername $PrimaryUsername
}

# Materialize decrypted wallpapers ahead of DSC so user.dsc.yml can resolve an
# explicit active wallpaper path deterministically.
$wallpaperOutputDir = Join-Path -Path $HOME -ChildPath "Pictures\wallpapers"

# Post-materialization health check: verify all SOPS files are decryptable by
# both the GPG and personal SSH age backends, and that managed artefacts exist.
# Mirrors the POSIX verifySecretDecryption Home Manager activation.
Invoke-NucleusSecretVerification `
  -GpgExe $gpgExe `
  -HostKeyPath $machineSshHostKeyPath `
  -PrimaryUsername $PrimaryUsername `
  -SecretsDir $secretsDir `
  -WallpaperAssetsDir $wallpaperAssetsDir

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
# Re-run host age key registration after Sync-NucleusOpenSshServer has started
# the sshd service (which generates host keys on a fresh machine).  This second
# call is a no-op when the key is already registered; on first-ever apply it
# completes registration in the same run without requiring a second apply.
if ($EnableHostAgeKeyRegistration) {
  Register-NucleusHostAgeKey `
    -MachineSshHostKeyPubPath $machineSshHostKeyPubPath `
    -SopsExe $sopsExe `
    -SopsYamlPath $sopsYamlPath `
    -SecretsDir $secretsDir `
    -WallpaperAssetsDir $wallpaperAssetsDir
}
Sync-NucleusWindowsRdp -Enabled:$EnableRdpParity
Sync-NucleusPowerPolicy -Enabled:$EnablePowerParity

# Health check: verify archiving ecosystem (7-Zip CLI + app) is functional post-apply.
Test-NucleusArchivingStack | Out-Null
