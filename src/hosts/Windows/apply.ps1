<#
.SYNOPSIS
  Apply the configuration for Windows.
.DESCRIPTION
  Loads the helper modules, materializes secrets and wallpapers, applies every
  DSC file through Invoke-WingetConfiguration, provisions Scoop, cargo-binstall
  and bun, then converges user-level shell, editor, Git/SSH, remote-access and
  power state. Idempotent: a rerun re-applies and repairs drift.
.PARAMETER ConfigFiles
  Ordered DSC filenames, resolved against $ConfigDir. Per-user files declared in
  src/users/<username>/windows.json under dscConfigFiles are appended for every
  user in -Users, de-duplicated and order-preserving.
.PARAMETER ModuleDir
  Directory of one-function Windows helper modules. Mandatory, so callers know
  which modules run.
.PARAMETER Users
  Usernames to configure. Mandatory. Each user gets secrets materialized, SSH
  keys adopted and home directory state converged, so the session user must
  appear here. Run once per user to keep secret materialization isolated.
.PARAMETER NoAISync
  Skip the post-apply Ollama model sync, whose model pulls run 2-20 GB each.
.PARAMETER ReplicaSync
  Run the post-apply cloud replica sync, which apply skips by default because a
  scheduled daily sync already converges replicas.
.PARAMETER VMSetup
  Run full post-apply VM provisioning (image build and disk setup), which
  includes config sync. Off by default because disk pre-allocation is slow.
.PARAMETER NoVMSync
  Skip the lightweight VM descriptor and script refresh apply runs after every
  apply.
.PARAMETER Action
  Command surface to run: "apply" (default), or "health-check" and "audit-store",
  which are stubs that report not-implemented and exit 0.
.NOTES
  Environment: NUCLEUS_REPO_ROOT, NUCLEUS_HOST (must be "Windows"), USERNAME,
  HOME, LOCALAPPDATA, ProgramData, ProgramFiles, USERPROFILE.
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = $PSScriptRoot,
  [string[]]$ConfigFiles = @("system/env.dsc.yml", "system/scheduler.dsc.yml", "system/scheduler-user.dsc.yml", "system/developer-mode.dsc.yml", "system/firewall.dsc.yml", "system/taskbar.dsc.yml", "system/computer-name.dsc.yml", "system/long-paths.dsc.yml", "system/storage-sense.dsc.yml", "system/font-substitutes.dsc.yml", "system/remote-desktop.dsc.yml", "system/power-policy.dsc.yml", "system/hyperv.dsc.yml", "system/packages.dsc.yml"),
  [Alias("h")]
  [switch]$Help,
  [Parameter(Mandatory)]
  [string]$ModuleDir,
  [Parameter(Mandatory)]
  [string[]]$Users,
  [switch]$NoOptionalParity,
  [switch]$NoSecretsParity,
  [switch]$NoUserStateParity,
  [switch]$NoSystemParity,
  [int]$MinFreeDiskGB = 10,
  [switch]$NoAISync,
  [switch]$ReplicaSync,
  [switch]$NoVMSync,
  [switch]$VMSetup,
  [switch]$Elevated,
  [string]$Action = "apply",
  [string]$ParamsJson = ""
)

$ErrorActionPreference = "Stop"

if ($ParamsJson -and (Test-Path $ParamsJson)) {
  $p = Get-Content $ParamsJson -Raw | ConvertFrom-Json
  $ConfigDir = $p.ConfigDir
  $ConfigFiles = [string[]]$p.ConfigFiles
  $ModuleDir = $p.ModuleDir
  $Users = [string[]]$p.Users
  $NoOptionalParity = [bool]$p.NoOptionalParity
  $NoSecretsParity = [bool]$p.NoSecretsParity
  $NoUserStateParity = [bool]$p.NoUserStateParity
  $NoSystemParity = [bool]$p.NoSystemParity
  $MinFreeDiskGB = [int]$p.MinFreeDiskGB
  $NoAISync = [bool]$p.NoAISync
  $ReplicaSync = [bool]$p.ReplicaSync
  $NoVMSync = [bool]$p.NoVMSync
  $VMSetup = [bool]$p.VMSetup
  $Elevated = $true
}

  # Load first: every module below emits Write-Nucleus* messages.
$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
Import-Module (Join-Path -Path $resolvedModuleDir -ChildPath "Format-NucleusOutput.psm1")

# Refuse to run as Administrator; elevation is managed internally.
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin -and -not $Elevated) {
  Write-NucleusError -CommandName apply "This script must not be run as Administrator. Run as a regular user (elevation is managed internally when needed)."
  exit 1
}

$actionRepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..")).Path
$applyScript = Join-Path -Path $actionRepoRoot -ChildPath "scripts\apply.ps1"
switch ($Action) {
  "health-check" {
    if (Test-Path -LiteralPath $applyScript) {
      & $applyScript health-check
    } else {
      Write-NucleusInfo -CommandName health-check "scripts/apply.ps1 not found; health-check is not yet implemented for Windows; exiting 0"
    }
    exit 0
  }
  "audit-store" {
    if (Test-Path -LiteralPath $applyScript) {
      & $applyScript audit-store
    } else {
      Write-NucleusInfo -CommandName audit-store "scripts/apply.ps1 not found; audit-store is not yet implemented for Windows; exiting 0"
    }
    exit 0
  }
  "apply" {
  }
  default {
    Write-NucleusError -CommandName apply "Unknown action '$Action'. Valid actions: apply, health-check, audit-store."
    exit 1
  }
}

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$noOptionalParity = $NoOptionalParity
$noSecretsParity = $NoSecretsParity -or $noOptionalParity
$noUserStateParity = $NoUserStateParity -or $noOptionalParity
$noSystemParity = $NoSystemParity -or $noOptionalParity

$EnableSecretsParity = -not $noSecretsParity

$EnableHostAgeKeyRegistration = -not $noSystemParity
$EnableRemoteAccessParity = -not $noSystemParity
$EnableRdpParity = -not $noSystemParity
$EnablePowerParity = -not $noSystemParity
$EnableWiFiParity = -not $noSystemParity

$EnableAgentsConfigParity = -not $noUserStateParity
$EnableAgentsSkillsParity = -not $noUserStateParity
$EnableAgentsClawHubSkillsParity = -not $noUserStateParity
$EnablePiExtensionsParity = -not $noUserStateParity
$EnableOpenCodeConfigParity = -not $noUserStateParity
$EnableSuperpowersParity = -not $noUserStateParity
$EnableWhisperModelParity = -not $noUserStateParity
$EnableBunParity = -not $noUserStateParity
$EnableCloudDrivesParity = -not $noUserStateParity
$EnableSymlinkParity = -not $noUserStateParity
$EnableGitSshParity = -not $noUserStateParity
$EnablePicardParity = -not $noUserStateParity
$EnableObsidianParity = -not $noUserStateParity
$EnableRimSortParity = -not $noUserStateParity
$EnableQtPassParity = -not $noUserStateParity
$EnableLibreOfficeParity = -not $noUserStateParity
$EnableShellParity = -not $noUserStateParity
$EnableDevDirectoryParity = -not $noUserStateParity
$EnableDiscordMusicRPCParity = -not $noUserStateParity
$EnableCamillaDSPServiceParity = -not $noUserStateParity
$EnableCamillaDSPHeartbeatServiceParity = -not $noUserStateParity
$EnableCamillaGUIServiceParity = -not $noUserStateParity
$EnableAppAutostartParity = -not $noUserStateParity
$EnableMenuBarParity = -not $noUserStateParity
$EnableDevReposParity = if ($noUserStateParity) { $false } else { $null }
$EnableVsCodeExtensionsParity = -not $noUserStateParity
$EnableVsCodeSettingsParity = -not $noUserStateParity
$EnableVsCodeWorkspaceTrustParity = -not $noUserStateParity
$EnablePiProjectTrustParity = -not $noUserStateParity
$EnableHarnessBridgeParity = -not $noUserStateParity

$secretsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "secrets"
$systemModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "system"
$setupModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "setup"
$userModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "user"
$editorsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "editors"
$wallpapersModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "wallpapers"

if (-not $Elevated) {
  $params = @{
    ConfigDir        = $ConfigDir
    ConfigFiles      = $ConfigFiles
    ModuleDir        = $ModuleDir
    Users            = $Users
    NoOptionalParity  = $NoOptionalParity
    NoSecretsParity   = $NoSecretsParity
    NoUserStateParity = $NoUserStateParity
    NoSystemParity    = $NoSystemParity
    MinFreeDiskGB     = $MinFreeDiskGB
    NoAISync         = $NoAISync
    ReplicaSync      = $ReplicaSync
    NoVMSync         = $NoVMSync
    VMSetup          = $VMSetup
    Elevated         = $true
  }
  $paramsJsonPath = [System.IO.Path]::GetTempFileName() + ".json"
  $params | ConvertTo-Json -Compress | Set-Content $paramsJsonPath -Encoding utf8 -NoNewline

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Process -Id $PID).Path
  $psi.Arguments = "-NoProfile -File `"$PSCommandPath`" -ParamsJson `"$paramsJsonPath`""
  $psi.Verb = "RunAs"
  $psi.UseShellExecute = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  if ($null -eq $proc) {
    Remove-Item $paramsJsonPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: cleanup of temp file; failure is harmless (OS will eventually clean %TEMP%)
    throw "User cancelled the elevation prompt (UAC). nucleus-apply requires elevation for system configuration."
  }
  $proc.WaitForExit()
  $exitCode = $proc.ExitCode
  Remove-Item $paramsJsonPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: same -- temp file in %TEMP%; child may have already cleaned up
  exit $exitCode
}

# Load first: modules below read $nucleusPathComponents, $nucleusPrependRegistry,
# and Get-NucleusManagedBinDir.
. (Join-Path -Path $resolvedModuleDir -ChildPath "ManagedPaths.ps1")

# Config helpers (Deploy-WritableSymlink, Resolve-UserConfigSource) load before
# any Sync-* module deploys a managed config.
. (Join-Path -Path $resolvedModuleDir -ChildPath "New-NucleusHub.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "ConfigHelpers.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Load-UserRegistry.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-LogManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Resolve-Executable.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Test-ArchivingStack.ps1")
# Load before the apply-time health re-arm, which calls Clear-HealthRecordAll.
. (Join-Path -Path $resolvedModuleDir -ChildPath "ServiceHealth.ps1")
# secrets/: decryption, SOPS age key management, and secret materialization.
# ConvertFrom-SshEd25519PublicKeyToAgePubKey must be loaded before any file that
# calls it (Register-HostAgeKey, Invoke-SecretVerification).
. (Join-Path -Path $secretsModuleDir -ChildPath "ConvertFrom-SshEd25519PublicKeyToAgePubKey.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Get-Secret.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Get-DecryptedBlob.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Invoke-JITSecretMaterialization.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Invoke-SecretVerification.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Register-HostAgeKey.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Remove-ManagedSecret.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Sync-SecretFile.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Sync-UserSecret.ps1")
# system/: machine-level services and infrastructure (WinGet, SSH host, RDP, power, AI).
. (Join-Path -Path $systemModuleDir -ChildPath "Initialize-SSHHostKey.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-AISync.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-ReplicaSync.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-VMSetup.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-PostApply.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-AgentHostShellSetup.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-SteamCMDSetup.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-EnsureLogDir.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "ConvertFrom-WingetLockfileToDsc.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-WingetConfiguration.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-CaddyLocalCA.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-JellyfinAccountCatalog.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-JellyfinLibraryCatalog.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-CaddyService.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-LiteLLMService.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-RedisService.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-ReplicaSyncScheduledTask.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-OpenSSHServer.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-PowerPolicy.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-WifiMacRandomization.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-TerminalActivation.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-WindowsRDP.ps1")
# setup/: one-time or infrequent toolchain provisioning (Scoop, Bun, Cargo, prek, PowerShell modules).
. (Join-Path -Path $setupModuleDir -ChildPath "Initialize-DevDirectory.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Install-PrekHook.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-BunSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CamillaDSPSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CamillaGUISetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CargoBinstallSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-PiSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-PowerShellModuleSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-RustupSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-ScoopSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-SourceBuild.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-UvSetup.ps1")
# user/: per-user home convergence (git/SSH, shell, agents, dev repos, apps).
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CloudDriveCatalog.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsClawHubSkillManifest.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsSkillManifest.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CursorConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-PiAgentConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-OpenCodeConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-SuperpowersPlugin.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-WhisperModel.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-SymlinkManifest.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DevRepoCatalog.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DiscordMusicRPC.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaDSPService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaDSPHeartbeatService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaGUIService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AppAutostart.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-MenuBar.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-GitAndSshConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ObsidianConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-RimSortConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-PicardConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-QtPassConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-BunConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-UvConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ShellProfile.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-NextestConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DirenvConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-LibreOfficeXcu.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-StarshipConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-SrtConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-HermesConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-HarnessBridge.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-UserPath.ps1")
# editors/: VS Code configuration and workspace management.
. (Join-Path -Path $editorsModuleDir -ChildPath "Set-VSCodeWorkspaceTrust.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Set-PiProjectTrust.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeExtensionManifest.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-CursorExtensionManifest.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeSettingManifest.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeConfig.ps1")
# wallpapers/: wallpaper materialization and stale-file cleanup.
. (Join-Path -Path $wallpapersModuleDir -ChildPath "Remove-StaleWallpaper.ps1")
. (Join-Path -Path $wallpapersModuleDir -ChildPath "Sync-WallpaperInventory.ps1")

# Load the user registry from src/users/ domain files, which defines every user
# this host manages. Validate that all users in -Users are registered.
$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
$machineSshHostKeyPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key"

# Resolve managed executables before running any decryption/materialization.
# check-suppress:suppression_doc: probe -- SOPS WinGet package directory may not exist; $null check handles absence.
$sopsPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Packages\SecretsOPerationS.SOPS_*") -Directory -ErrorAction SilentlyContinue |
  Sort-Object -Property Name -Descending |
  Select-Object -First 1

$sopsExecutableFromWinget = $null
if ($null -ne $sopsPackageDir) {
  $sopsExecutableFromWinget = Join-Path -Path $sopsPackageDir.FullName -ChildPath "sops.exe"
}

$sopsCandidates = @(
  $sopsExecutableFromWinget,
  # check-suppress:suppression_doc: probe whether sops is on PATH; Get-Command throws when absent.
  (Get-Command -Name "sops.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$gpgCandidates = @(
  (Join-Path -Path $env:ProgramFiles -ChildPath "GnuPG\bin\gpg.exe"),
  # WHY: standalone GnuPG (GnuPG.GnuPG) installs to Program Files (x86) on x64 systems.
  (Join-Path -Path "${env:ProgramFiles(x86)}" -ChildPath "GnuPG\bin\gpg.exe"),
  # check-suppress:suppression_doc: probe whether gpg is on PATH; Get-Command throws when absent.
  (Get-Command -Name "gpg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$sshKeygenCandidates = @(
  # The OpenSSH client ships in System32 on Windows 10 1809+ and Server 2019+.
  (Join-Path -Path $env:SystemRoot -ChildPath 'System32\OpenSSH\ssh-keygen.exe'),
  # Git for Windows carries its own ssh-keygen, used when the inbox client is absent.
  (Join-Path -Path $env:ProgramFiles -ChildPath 'Git\usr\bin\ssh-keygen.exe'),
  # check-suppress:suppression_doc: probe whether ssh-keygen is on PATH; Get-Command throws when absent.
  (Get-Command -Name "ssh-keygen.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# check-suppress:suppression_doc: probe -- prek WinGet package directory may not exist; $null check handles absence.
$prekPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Packages\j178.Prek_*") -Directory -ErrorAction SilentlyContinue |
  Sort-Object -Property Name -Descending |
  Select-Object -First 1

$prekExecutableFromWinget = $null
if ($null -ne $prekPackageDir) {
  # check-suppress:suppression_doc: probe -- prek executable may not be in expected location; $null check handles absence.
  $prekExecutableFromWinget = Get-ChildItem -Path $prekPackageDir.FullName -Filter "prek*.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object -Property FullName |
    Select-Object -First 1 -ExpandProperty FullName
}

$prekCandidates = @(
  $prekExecutableFromWinget,
  # check-suppress:suppression_doc: probe whether prek is on PATH; Get-Command throws when absent.
  (Get-Command -Name "prek.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
  # check-suppress:suppression_doc: fallback probe without .exe suffix.
  (Get-Command -Name "prek" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$sopsExe = Resolve-Executable -Name "sops" -CandidatePaths $sopsCandidates
$gpgExe = Resolve-Executable -Name "gpg" -CandidatePaths $gpgCandidates
$sshKeygenExe = Resolve-Executable -Name "ssh-keygen" -CandidatePaths $sshKeygenCandidates
$prekExe = if ($prekCandidates.Count -gt 0) {
  Resolve-Executable -Name "prek" -CandidatePaths $prekCandidates
} else {
  $null
}

$secretsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets"
$machineSshHostKeyPubPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key.pub"
$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\")).Path

$userRegistry = & (Join-Path -Path $resolvedModuleDir -ChildPath "Load-UserRegistry.ps1") -RepoRoot $repoRoot
$registeredUserNames = @($userRegistry.users.name)
$selectedUserRecords = @($userRegistry.users | Where-Object { $Users -contains $_.name })

foreach ($user in $Users) {
  if ($user -notin $registeredUserNames) {
    Write-NucleusError -CommandName apply "User '$user' not found in registry. Registered users: $($registeredUserNames -join ', ')" -ErrorAction Stop
    exit 1
  }
}

$effectiveConfigFiles = @($ConfigFiles)
foreach ($configuredUser in $userRegistry.users) {
  if ($configuredUser.name -notin $Users) {
    continue
  }

  foreach ($userConfigFile in @($configuredUser.dscConfigFiles)) {
    if ([string]::IsNullOrWhiteSpace($userConfigFile)) {
      continue
    }
    # Path traversal guard: entries must be plain filenames relative to user/.
    if ($userConfigFile -match '[\\/]|\.\.') {
      throw "User '$($configuredUser.name)' dscConfigFiles entry '$userConfigFile' contains path separators or '..'; entries must be plain filenames relative to the user/ directory"
    }
    $resolvedConfigFile = "user/$userConfigFile"
    if ($resolvedConfigFile -notin $effectiveConfigFiles) {
      $effectiveConfigFiles += $resolvedConfigFile
    }
  }
}

if (-not $userRegistry.primaryUser) {
  Write-NucleusError -CommandName 'apply' "No primary user marked (isPrimary=true) in user registry"
  exit 1
}

$primaryUser = $userRegistry.primaryUser.name
$sessionUser = [Environment]::UserName
if ($Users -notcontains $sessionUser) {
  Write-NucleusError -CommandName 'apply' "current user '$sessionUser' must be included in -Users ($($Users -join ', '))"
  exit 1
}
$primarySshKeyPath = Join-Path -Path $userRegistry.primaryUser.homeDirectory -ChildPath ".ssh\ssh_personal_$primaryUser"
$sessionUserRecord = @($userRegistry.users | Where-Object { $_.name -eq $sessionUser }) | Select-Object -First 1
$sessionWallpaperOutputDir = Join-Path -Path $sessionUserRecord.homeDirectory -ChildPath "Pictures\wallpapers"
$sopsYamlPath = Join-Path -Path $repoRoot -ChildPath ".sops.yaml"

$env:NUCLEUS_REPO_ROOT = $repoRoot

$env:NUCLEUS_HOST = "Windows"

$existingRoot = [Environment]::GetEnvironmentVariable("NUCLEUS_REPO_ROOT", "Machine")
if ($existingRoot -ne $repoRoot) {
  [Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $repoRoot, "Machine")
  Write-NucleusInfo -CommandName 'apply' "set NUCLEUS_REPO_ROOT=$repoRoot (Machine scope)"
  if ($null -ne [Environment]::GetEnvironmentVariable("NUCLEUS_REPO_ROOT", "User")) {
    [Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $null, "User")
  }
}

if ($EnableHostAgeKeyRegistration) {
  Initialize-SSHHostKey -MachineSshHostKeyPath $machineSshHostKeyPath
}

if ($EnableHostAgeKeyRegistration) {
  Register-HostAgeKey `
    -MachineSshHostKeyPubPath $machineSshHostKeyPubPath `
    -SopsExe $sopsExe `
    -SopsYamlPath $sopsYamlPath `
    -SecretsDir $secretsDir `
    -RepoRoot $repoRoot
}

# The per-user ~/.nucleus hub (user -> %LOCALAPPDATA%\nucleus,
# system -> %ProgramData%\nucleus) needs the elevated context to create
# junctions under each profile.
foreach ($user in $Users) {
  $userRecord = @($userRegistry.users | Where-Object { $_.name -eq $user }) | Select-Object -First 1
  if ($null -eq $userRecord -or [string]::IsNullOrWhiteSpace($userRecord.homeDirectory)) {
    Write-NucleusWarning -CommandName 'apply' "skipping hub creation for '$user': homeDirectory not found in registry."
    continue
  }
  New-NucleusHub -UserHome $userRecord.homeDirectory
}

if ($EnableSecretsParity) {
  foreach ($user in $Users) {
    $userRecord = @($userRegistry.users | Where-Object { $_.name -eq $user }) | Select-Object -First 1
    $targetSshKeyPath = Join-Path -Path $userRecord.homeDirectory -ChildPath ".ssh\ssh_personal_$user"
    if (-not (Test-Path -Path $targetSshKeyPath -PathType Leaf)) {
      $targetSshKeyPath = $primarySshKeyPath
    }
    $syncUserSecretParams = @{
      RepoRoot    = $repoRoot
      GpgExe      = $gpgExe
      HostKeyPath = $machineSshHostKeyPath
      SopsExe     = $sopsExe
      Username    = $user
    }
    if (-not [string]::IsNullOrWhiteSpace($targetSshKeyPath)) {
      $syncUserSecretParams['SshKeyFallbackPath'] = $targetSshKeyPath
    }
    Sync-UserSecret @syncUserSecretParams
  }
}
else {
  Remove-ManagedSecret -Users $Users
}


foreach ($user in $Users) {
  $userSecretFile = Join-Path -Path $secretsDir -ChildPath "users\$user.yml"
  if (-not (Test-Path -Path $userSecretFile -PathType Leaf)) {
    continue
  }
  Invoke-SecretVerification `
    -GpgExe $gpgExe `
    -SshKeygenExe $sshKeygenExe `
    -HostKeyPath $machineSshHostKeyPath `
    -Username $user `
    -SecretsDir $secretsDir `
    -RepoRoot $repoRoot
}

$activeWallpaperPath = Sync-WallpaperInventory -RepoRoot $repoRoot -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -Users $Users -SopsExe $sopsExe
Remove-StaleWallpaper -RepoRoot $repoRoot -User $sessionUser -OutputDir $sessionWallpaperOutputDir

$lockfilePath = Join-Path -Path $PSScriptRoot -ChildPath "..\..\lockfiles\lockfile.json"
$generatedDir = Join-Path -Path $resolvedConfigDir -ChildPath ".generated"
New-Item -Path $generatedDir -ItemType Directory -Force > $null
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/scheduler.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/scheduler.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/scheduler-user.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/scheduler-user.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/developer-mode.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/developer-mode.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/firewall.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/firewall.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/taskbar.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/taskbar.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/computer-name.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/computer-name.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/long-paths.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/long-paths.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/storage-sense.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/storage-sense.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/font-substitutes.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/font-substitutes.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/remote-desktop.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $generatedDir -ChildPath "system/remote-desktop.locked.dsc.yml")

$wingetPackagesPath = Join-Path -Path $PSScriptRoot -ChildPath "..\..\hosts\Windows\system\winget-packages.json"
$enabledWingetPackages = $null
if (Test-Path -Path $wingetPackagesPath) {
  try {
    $wingetPkgDoc = Get-Content -Path $wingetPackagesPath -Raw | ConvertFrom-Json -AsHashtable
    $enabledWingetPackages = @{}
    foreach ($pkgId in $wingetPkgDoc['packages']) {
      $enabledWingetPackages[$pkgId] = $true
    }
    Write-NucleusInfo -CommandName 'apply' "loaded $($enabledWingetPackages.Count) enabled WinGet packages from winget-packages.json"
  } catch {
    Write-NucleusWarning -CommandName 'apply' "winget-packages.json parse failed, emitting all packages"
  }
} else {
  Write-NucleusWarning -CommandName 'apply' "winget-packages.json not found at $wingetPackagesPath, emitting all packages"
}
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/packages.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/packages.locked.dsc.yml") -EnabledPackages $enabledWingetPackages

$effectiveConfigFiles = @($effectiveConfigFiles | ForEach-Object {
  if ($_ -eq "system/scheduler.dsc.yml") { ".generated/system/scheduler.locked.dsc.yml" }
  elseif ($_ -eq "system/scheduler-user.dsc.yml") { ".generated/system/scheduler-user.locked.dsc.yml" }
  elseif ($_ -eq "system/developer-mode.dsc.yml") { ".generated/system/developer-mode.locked.dsc.yml" }
  elseif ($_ -eq "system/firewall.dsc.yml") { ".generated/system/firewall.locked.dsc.yml" }
  elseif ($_ -eq "system/taskbar.dsc.yml") { ".generated/system/taskbar.locked.dsc.yml" }
  elseif ($_ -eq "system/computer-name.dsc.yml") { ".generated/system/computer-name.locked.dsc.yml" }
  elseif ($_ -eq "system/long-paths.dsc.yml") { ".generated/system/long-paths.locked.dsc.yml" }
  elseif ($_ -eq "system/storage-sense.dsc.yml") { ".generated/system/storage-sense.locked.dsc.yml" }
  elseif ($_ -eq "system/font-substitutes.dsc.yml") { ".generated/system/font-substitutes.locked.dsc.yml" }
  elseif ($_ -eq "system/remote-desktop.dsc.yml") { ".generated/system/remote-desktop.locked.dsc.yml" }
  elseif ($_ -eq "system/packages.dsc.yml") { ".generated/system/packages.locked.dsc.yml" }
  else { $_ }
})

foreach ($configFile in $effectiveConfigFiles) {
  Invoke-WingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile) -WallpaperPath $activeWallpaperPath
}

wevtutil sl Application /ms:209715200 2>$null  # check-suppress:suppression_doc: may already be at desired size; wevtutil exits non-zero but this is harmless

# After WinGet DSC installs Scoop.Scoop, since the shims directory is not on
# PATH until Invoke-ScoopSetup prepends it.
# rustup runs after WinGet DSC installs Rustlang.Rustup, and before
# Invoke-CargoBinstallSetup so the stable toolchain and its cargo binary exist
# for the compilation fallback.
Invoke-RustupSetup -User $sessionUser -RepoRoot $repoRoot
Invoke-ScoopSetup
# After Invoke-ScoopSetup installs cargo-binstall and prepends the shims
# directory to PATH.
Invoke-CargoBinstallSetup
# After WinGet DSC installs Oven-sh.Bun; Invoke-BunSetup prepends ~/.bun/bin
# to PATH for this session.
if ($EnableBunParity) {
  Invoke-BunSetup
}
# pi itself is a bun global package, so this runs after Invoke-BunSetup made
# the pi CLI reachable.
if ($EnablePiExtensionsParity) {
  Invoke-PiSetup
}
# After WinGet DSC installs astral-sh.uv; Invoke-UvSetup prepends ~/.local/bin
# to PATH for this session.
Invoke-UvSetup
# PowerShell modules: pinned versions for DSC validation and code hygiene.
Invoke-PowerShellModuleSetup
Invoke-CamillaDSPSetup
# camillagui-backend prebuilt bundle (same rationale as CamillaDSP).
Invoke-CamillaGUISetup
Invoke-SourceBuild

Install-PrekHook -PrekExecutablePath $prekExe -RepositoryRoot $repoRoot

$currentUser = [System.Environment]::UserName
$userDevRepos = $null
foreach ($user in $userRegistry.users) {
  if ($user.name -eq $currentUser) {
    $userDevRepos = $user.devRepos
    break
  }
}

$devRepositories = @()
$devReposEnabled = $false

if ($userDevRepos -and $userDevRepos.repositories) {
  $devReposEnabled = if ($userDevRepos.enable) { $true } else { $false }
  $userHome = [Environment]::GetFolderPath('UserProfile')
  foreach ($repo in $userDevRepos.repositories) {
    $repoEntry = @{
      name   = $repo.name
      target = (Join-Path -Path $userHome -ChildPath $repo.target)
    }

    if ($repo.symlinkFromRepoRoot) {
      $repoEntry.symlink = $repoRoot
    }
    elseif ($repo.url) {
      $repoEntry.url = $repo.url
    }

    $devRepositories += $repoEntry
  }
}

$superpowersSkillsSource = Join-Path -Path (Get-NucleusUserRoot) -ChildPath 'plugins\superpowers\skills'

Sync-AgentsConfig -RepoRoot $repoRoot -User $sessionUser -Enabled:$EnableAgentsConfigParity
Sync-SuperpowersPlugin -RepoRoot $repoRoot -Enabled:$EnableSuperpowersParity
Sync-WhisperModel -RepoRoot $repoRoot -Enabled:$EnableWhisperModelParity
Sync-OpenCodeConfig -RepoRoot $repoRoot -User $sessionUser -Enabled:$EnableOpenCodeConfigParity
Sync-AgentsSkillManifest -RepoRoot $repoRoot -User $sessionUser -Enabled:$EnableAgentsSkillsParity -ExtraSkillsSource $superpowersSkillsSource
Sync-PiAgentConfig -RepoRoot $repoRoot -User $sessionUser -Enabled:$EnablePiExtensionsParity
Sync-AgentsClawHubSkillManifest -RepoRoot $repoRoot -User $sessionUser -Enabled:$EnableAgentsClawHubSkillsParity
Sync-CursorConfig -RepoRoot $repoRoot -Enabled:$EnableAgentsConfigParity -Username $sessionUser
Sync-VSCodeConfig -RepoRoot $repoRoot -Enabled:$EnableVsCodeSettingsParity -Username $sessionUser
Sync-VSCodeExtensionManifest -Enabled:$EnableVsCodeExtensionsParity
Sync-CursorExtensionManifest -Enabled:$EnableVsCodeExtensionsParity
Initialize-DevDirectory -Enabled:$EnableDevDirectoryParity
Set-VSCodeWorkspaceTrust -Enabled:$EnableVsCodeWorkspaceTrustParity
Set-PiProjectTrust -Enabled:$EnablePiProjectTrustParity
Sync-GitAndSshConfig -Enabled:$EnableGitSshParity -Users $Users
# check-suppress:config-method: method 3 (merge) -- LibreOffice owns registrymodifications.xcu and
# overwrites it on exit. A symlink would be replaced. Merge injects managed
# entries while preserving user-configured settings outside managed keys.
Sync-LibreOfficeXcu -Enabled:$EnableLibreOfficeParity -Users $selectedUserRecords -RepoRoot $repoRoot
Sync-ObsidianConfig -Enabled:$EnableObsidianParity -Users $selectedUserRecords -RepoRoot $repoRoot
# check-suppress:config-method: method 3 (merge) -- RimSort owns settings.json and writes theme, sorting,
# and window state into it. A symlink would let app-owned writes reach the
# repo file. Merge preserves both managed and app-owned keys.
Sync-RimSortConfig -Enabled:$EnableRimSortParity -Users $selectedUserRecords -HostName $env:NUCLEUS_HOST -RepoRoot $repoRoot
Invoke-SteamCMDSetup -Enabled:$EnableRimSortParity -Users $selectedUserRecords -RepoRoot $repoRoot
# check-suppress:config-method: method 3 (merge) -- Picard defaults INI merged via Sync-PicardConfig on Windows
Sync-PicardConfig -Enabled:$EnablePicardParity -Users $selectedUserRecords -RepoRoot $repoRoot
# WHY: QtPass stores settings in platform-native stores (registry on Windows), so Method 1 (symlink) does not apply.
# check-suppress:config-method: method 3 (merge) -- QtPass shared settings JSON source of truth shared with POSIX activation
Sync-QtPassConfig -Enabled:$EnableQtPassParity -Users $selectedUserRecords -RepoRoot $repoRoot
# Default to false if devReposEnabled not yet set (user not in registry or no repos configured).
if ($null -eq $EnableDevReposParity) {
  $EnableDevReposParity = $devReposEnabled
}

# After Git/SSH config, so clones see the same secret and key ordering as
# macOS and NixOS.
Sync-DevRepoCatalog -Enabled:$EnableDevReposParity -Repositories $devRepositories
Sync-ShellProfile -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
# check-suppress:config-method: method 1 (writable symlink) -- bun and uv configs symlinked to repo files.
Sync-BunConfig -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
Sync-UvConfig -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
Sync-NextestConfig -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
# check-suppress:config-method: method 1 (writable symlink) -- direnvrc cross-platform base config.
Sync-DirenvConfig -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
Sync-StarshipConfig -Enabled:$EnableShellParity -User $sessionUser -RepoRoot $repoRoot
Sync-SrtConfig -Enabled:$true -User $sessionUser -RepoRoot $repoRoot
Sync-HermesConfig -Enabled:$true -User $sessionUser -RepoRoot $repoRoot
# Hook entry points must resolve by bare name from harness-spawned processes,
# so they are deployed to the USER root with .cmd shims on the managed PATH.
Sync-HarnessBridge -Enabled:$EnableHarnessBridgeParity -RepoRoot $repoRoot -UserRoot (Get-NucleusUserRoot) -UserProfile $HOME
if ($EnableCloudDrivesParity) {
  foreach ($userRecord in $selectedUserRecords) {
    Sync-CloudDriveCatalog -UserConfig $userRecord -HomeDirectory $userRecord.homeDirectory
  }
}
# The health re-arm clears every instance record so no blocked state or loop
# history survives an apply. A block otherwise clears only on reboot, when the
# record's boot id stops matching, so a blocked service would stay blocked even
# though apply just restarted it. Mirrors the POSIX
# home.activation.reset-service-health step in src/modules/cloud-drives.nix.
Clear-HealthRecordAll
# Ensure the log subdirectories exist before services start.
Invoke-EnsureLogDir -ServicesJson (Join-Path -Path $repoRoot -ChildPath "src\modules\services.json")
Sync-CaddyService -RepoRoot $repoRoot -Enabled:`$true
Sync-CaddyLocalCA -RepoRoot $repoRoot -Enabled:$true
Sync-JellyfinAccountCatalog -RepoRoot $repoRoot -UserRecords $selectedUserRecords -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe
Sync-JellyfinLibraryCatalog -RepoRoot $repoRoot -UserRecords $selectedUserRecords -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe
Sync-SymlinkManifest -Enabled:$EnableSymlinkParity -UserRecords $selectedUserRecords
Sync-DiscordMusicRPC -Enabled:$EnableDiscordMusicRPCParity -RepoRoot $repoRoot -User $sessionUser
Sync-CamillaDSPService -Enabled:$EnableCamillaDSPServiceParity
Sync-CamillaDSPHeartbeatService -Enabled:$EnableCamillaDSPHeartbeatServiceParity
Sync-CamillaGUIService -Enabled:$EnableCamillaGUIServiceParity
Sync-AppAutostart -Enabled:$EnableAppAutostartParity -RepoRoot $repoRoot
Sync-MenuBar -Enabled:$EnableMenuBarParity -RepoRoot $repoRoot
Sync-LiteLLMService -RepoRoot $repoRoot -Enabled:`$true -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -SopsExe $sopsExe -PrimarySshKeyPath $primarySshKeyPath -SecretsDir $secretsDir
Sync-RedisService -RepoRoot $repoRoot -Enabled:`$true
Sync-ReplicaSyncScheduledTask -RepoRoot $repoRoot -Enabled:$EnableCloudDrivesParity
Sync-OpenSSHServer -Enabled:$EnableRemoteAccessParity
# Re-run after Sync-OpenSSHServer has started sshd, which generates host keys
# on a fresh machine. No-op once the key is registered, so a first apply
# completes without a second run.
if ($EnableHostAgeKeyRegistration) {
  Register-HostAgeKey `
    -MachineSshHostKeyPubPath $machineSshHostKeyPubPath `
    -SopsExe $sopsExe `
    -SopsYamlPath $sopsYamlPath `
    -SecretsDir $secretsDir `
    -RepoRoot $repoRoot
}
Sync-WindowsRDP -Enabled:$EnableRdpParity
Sync-PowerPolicy -Enabled:$EnablePowerParity
Sync-UserPath -Enabled:$EnableShellParity
Sync-WifiMacRandomization -Enabled:$EnableWiFiParity
Sync-TerminalActivation
# WHY: terminal-activations (last resort): this stage runs in the user's
# terminal context (outside the Nix rebuild) for macOS TCC-sensitive commands.
# On Windows the manifest is absent by default (no TCC constraints), but the
# mechanism is shared cross-platform.  See src/modules/terminal-activations.nix
# for the full policy.
Invoke-AgentHostShellSetup

# Post-apply provisioning: service verification, AI sync, replica sync,
# VM setup/sync, garbage collection, and manual display.
Invoke-PostApply -RepoRoot $repoRoot -ModuleDir $systemModuleDir `
  -NoAISync:$NoAISync -ReplicaSync:$ReplicaSync `
  -VMSetup:$VMSetup -NoVMSync:$NoVMSync
