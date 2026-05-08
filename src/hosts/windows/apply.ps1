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
    6. Provision Scoop buckets, cargo-binstall, and bun global packages.
    7. Converge user-level shell/editor/Git/SSH parity state.
    8. Converge remote-access and power posture parity state.
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

.PARAMETER EnableAgentsConfigParity
  Enable managed user-level agents config junction (%USERPROFILE%\.agents ->
  src\modules\configs\agents\) so coding agents write directly into the repo
  tree.  False removes the managed junction (cleanup path).

.PARAMETER EnableSecretsParity
  Enable managed secret materialization and managed SSH key cleanup fallback.

.PARAMETER EnableBunParity
  Enable managed bun global package provisioning (pi-coding-agent and future bun-only tools).

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
  Enable managed VS Code config symlinks (settings, keybindings, MCP, tasks,
  snippets, prompts, profiles, and Copilot memories) pointing into the live
  repo tree.  False removes managed symlinks (cleanup path); VS Code recreates
  plain files on next launch.

.PARAMETER EnableVsCodeWorkspaceTrustParity
  Enable managed VS Code workspace trust for %USERPROFILE%\dev.  Writes the
  trust entry directly to state.vscdb via Bun's built-in bun:sqlite module so
  the folder opens without a trust prompt.  False skips the write; no cleanup
  is needed because VS Code manages its own trust DB state.

.PARAMETER SkipAiSync
  When specified, suppresses the post-apply Ollama model sync step.  Useful in
  CI or on low-bandwidth connections where model pulls (2-20 GB each) are
  undesirable.

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
  # Apply while skipping the post-apply Ollama model sync:
  .\apply.ps1 -SkipAiSync

.EXAMPLE
  # Apply while disabling machine age key auto-registration in .sops.yaml:
  .\apply.ps1 -EnableHostAgeKeyRegistration:$false

.EXAMPLE
  # Apply while disabling managed agents config junction (cleanup only):
  .\apply.ps1 -EnableAgentsConfigParity:$false

.EXAMPLE
  # Apply while disabling managed VS Code settings parity (cleanup only):
  .\apply.ps1 -EnableVsCodeSettingsParity:$false

.EXAMPLE
  # Apply while disabling managed VS Code workspace trust (skip only):
  .\apply.ps1 -EnableVsCodeWorkspaceTrustParity:$false

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
  [bool]$EnableAgentsConfigParity = $true,
  [bool]$EnableSecretsParity = $true,
  [bool]$EnableBunParity = $true,
  [bool]$EnableGitSshParity = $true,
  [bool]$EnableHostAgeKeyRegistration = $true,
  [bool]$EnablePowerParity = $true,
  [bool]$EnableRdpParity = $true,
  [bool]$EnableRemoteAccessParity = $true,
  [bool]$EnableShellParity = $true,
  [bool]$EnableVsCodeExtensionsParity = $true,
  [bool]$EnableVsCodeSettingsParity = $true,
  [bool]$EnableVsCodeWorkspaceTrustParity = $true,
  [int]$MinFreeDiskGB = 10,
  [switch]$SkipAiSync
)

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
. (Join-Path -Path $resolvedModuleDir -ChildPath "ai-sync.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "bun-setup.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "cargo-binstall-setup.ps1")
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
. (Join-Path -Path $resolvedModuleDir -ChildPath "scoop-setup.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "set-vscodeworkspacetrust.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "shell.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-agentsconfig.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleussecretfile.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleussecrets.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleusvscodeextensions.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleusvscodesettings.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-nucleuswallpapers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "sync-vscodeconfig.ps1")
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

# Expose the repo root to any subprocesses (e.g. DSC script resources) that
# may need to locate repo-relative files.  Also write it to a stable file path
# so Home Manager activation scripts (e.g. vscodeSymlinks in editors.nix) can
# read it after the sudo boundary that darwin-rebuild/nixos-rebuild crosses,
# where environment variables are not reliably propagated.
$env:NUCLEUS_REPO = $repoRoot
$nucleusConfigDir = Join-Path -Path $HOME -ChildPath ".config\nucleus"
if (-not (Test-Path -LiteralPath $nucleusConfigDir -PathType Container)) {
  New-Item -ItemType Directory -Path $nucleusConfigDir -Force | Out-Null
}
[System.IO.File]::WriteAllText(
  (Join-Path -Path $nucleusConfigDir -ChildPath "repo-root"),
  "$repoRoot`n",
  [System.Text.UTF8Encoding]::new($false)
)

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

# Scoop bucket and app provisioning must run after DSC installs Scoop.Scoop.
# scoop shims are written to a user-local directory that is not on PATH in
# the current session until explicitly prepended; Invoke-ScoopSetup handles
# that prepend internally.
Invoke-ScoopSetup
# cargo-binstall managed packages run after Invoke-ScoopSetup has installed
# cargo-binstall from Scoop and prepended the shims directory to PATH.
Invoke-CargoBinstallSetup
# bun global packages run after WinGet DSC has installed Oven-sh.Bun.
# bun-setup prepends ~/.bun/bin to PATH internally for this session.
if ($EnableBunParity) {
  Invoke-BunSetup
}

Sync-AgentsConfig -RepoRoot $repoRoot -Enabled:$EnableAgentsConfigParity
Sync-VscodeConfig -RepoRoot $repoRoot -Enabled:$EnableVsCodeSettingsParity
Sync-NucleusVsCodeExtensions -Enabled:$EnableVsCodeExtensionsParity
Set-VscodeWorkspaceTrust -Enabled:$EnableVsCodeWorkspaceTrustParity
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

# Converge locally installed Ollama models with the declarative manifest as the
# final step of every apply.  Model pulls are 2-20 GB, so this runs last to
# avoid blocking earlier configuration steps.  The sync is best-effort: a
# missing or unreachable ollama binary is informational, not a hard failure,
# because the system configuration has already been applied successfully.
if ($SkipAiSync) {
  Write-Host "nucleus: -SkipAiSync set; skipping post-apply model sync"
} else {
  $ollamaOnPath = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaOnPath) {
    Write-Host "nucleus: ollama not found in PATH; skipping post-apply model sync"
  } else {
    Write-Host "nucleus: running post-apply AI model sync..."
    Invoke-AiSync -RepoRoot $repoRoot
  }
}
