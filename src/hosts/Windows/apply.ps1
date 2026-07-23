<#
.SYNOPSIS
  Apply the configuration for Windows.

.DESCRIPTION
  Orchestrates the Windows configuration lifecycle in a single script:
    1. Load helper functions from $ModuleDir one-function module files.
    2. Materialize primary-user secrets from src/secrets via SOPS.
    3. Materialize wallpaper blobs and remove stale decrypted files.
    4. Resolve each DSC config file relative to $ConfigDir.
    5. Pass each file to Invoke-WingetConfiguration, which substitutes
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
  @('system/scheduler.dsc.yml', 'system/developer-mode.dsc.yml',
  'system/firewall.dsc.yml', 'system/taskbar.dsc.yml',
  'system/computer-name.dsc.yml', 'system/long-paths.dsc.yml',
  'system/storage-sense.dsc.yml', 'system/font-substitutes.dsc.yml',
  'system/remote-desktop.dsc.yml', 'system/packages.dsc.yml').
  Filenames are resolved relative to $ConfigDir.

  Per-user DSC files can be declared in users.json under each
  user's dscConfigFiles array.  apply.ps1 appends those files for every user
  listed in -Users (de-duplicated, preserving order) so each managed user can
  declare their own user-level DSC configs without editing script code.

.PARAMETER ModuleDir
  Path to the directory containing one-function Windows helper modules.
  Mandatory: caller must explicitly pass the module directory so they are
  aware of which modules will be loaded and executed.

.PARAMETER PrimaryUsername
  Username allowed to materialize user-scoped secrets. Defaults to the
  current interactive user. Deprecated: use -Users instead.

.PARAMETER Users
  Array of usernames to configure. Mandatory: each user in this list gets
  their secrets materialized, SSH keys adopted, and home directory state
  converged. Callers must explicitly pass this list so they are aware of
  which user profiles will be modified. The first user in the list is used
  for secrets materialization.
  Example: -Users @('admin', 'guest')

  Note: For full multi-user support where each user gets their own secrets,
  SSH keys, and home directory state, run apply.ps1 separately for each user:
    .\apply.ps1 -ModuleDir "C:\path\to\src\hosts\Windows\modules" -Users @('admin')
    .\apply.ps1 -ModuleDir "C:\path\to\src\hosts\Windows\modules" -Users @('guest')
  This ensures each user gets properly isolated secret materialization.

.PARAMETER EnableAgentsConfigParity
  Enable managed per-subdir symlinks in %USERPROFILE%\.agents\ pointing into
  src\modules\configs\agents\ (excluding skills\) so coding agents write
  directly into the repo tree.  False removes managed symlinks (cleanup path).

.PARAMETER EnableAgentsSkillsParity
  Enable managed per-skill symlinks in %USERPROFILE%\.agents\skills\ for
  committed (bundled / AGPL-compatible) skills in
  src\modules\configs\agents\skills\.  False removes managed skill symlinks
  (cleanup path); fetched clawhub downloads in that directory are left intact.

.PARAMETER EnableAgentsClawHubSkillsParity
  Download and update fetched (non-AGPL-compatible) skills listed in
  src\modules\configs\agents\clawhub-skills.json into
  %USERPROFILE%\.agents\skills\ via the ClawHub CLI.  False skips the sync;
  already-downloaded skill directories are left intact (no cleanup path needed
  because ClawHub downloads are self-contained real directories, not managed
  symlinks).

.PARAMETER EnableSecretsParity
  Enable managed secret materialization and managed SSH key cleanup fallback.

.PARAMETER EnableBunParity
  Enable managed bun global package provisioning (pi-coding-agent and future bun-only tools).

.PARAMETER EnableCloudDrivesParity
  Enable managed cloud drive mount directory provisioning and rclone remote verification
  for each configured user. False skips provisioning without error.

.PARAMETER EnableCustomProvisionSymlinkParity
  Enable managed custom symlink provisioning from users.json. Each link is created only
  for entries that declare a Windows target and receives delete-protection ACLs.
  False removes only previously managed custom symlinks.

.PARAMETER EnableGitSshParity
  Enable managed user-level Git/SSH parity convergence and block cleanup logic.

.PARAMETER EnableHostAgeKeyRegistration
  Register this machine's SSH host public key as an age recipient in .sops.yaml
  and rewrap all SOPS-encrypted files on first apply.  Idempotent: no-op when
  the key is already registered.  Disable to skip registration (e.g. on
  machines where the SSH host key is not yet a designated SOPS recipient).

.PARAMETER EnablePowerParity
  Enable managed Windows power policy parity convergence and cleanup fallback.

.PARAMETER EnablePicardParity
  Enable managed MusicBrainz Picard native INI convergence and cleanup fallback.

.PARAMETER EnableObsidianParity
  Enable managed Obsidian advanced-settings parity convergence and cleanup
  fallback while preserving unmanaged vault metadata in the live app config.

.PARAMETER EnableQtPassParity
  Enable managed QtPass Settings/Template tab parity convergence and cleanup fallback.

.PARAMETER EnableRdpParity
  Enable managed Windows built-in RDP convergence and cleanup fallback.

.PARAMETER EnableRemoteAccessParity
  Enable managed OpenSSH remote-access convergence and cleanup fallback.

.PARAMETER EnableWiFiParity
  Enable managed Wi-Fi MAC address randomization parity convergence and cleanup
  fallback.  Mirrors the NixOS networking.networkmanager.wifi.macAddress and
  macOS Private Wi-Fi Address features.

.PARAMETER EnableShellParity
  Enable managed PowerShell profile parity block and cleanup fallback.

.PARAMETER EnableVsCodeExtensionsParity
  Enable managed VS Code extension parity convergence and cleanup fallback.

.PARAMETER EnableVsCodeSettingsParity
  Enable managed VS Code config symlinks (settings, keybindings, MCP, tasks,
  snippets, prompts, profiles, and Copilot memories) pointing into the live
  repo tree.  False removes managed symlinks (cleanup path); VS Code recreates
  plain files on next launch.

.PARAMETER EnableDevDirectoryParity
  Create %USERPROFILE%\dev when absent.  Mirrors macOS configureSystemHardening
  and NixOS provisionDevDirectory which both provision ~/dev during activation.
  False skips creation without error.

.PARAMETER EnableDevReposParity
  Enable provisioning of development repositories (nucleus symlink, monorepo,
  and monorepo-private) in %USERPROFILE%\dev. Defaults to enabled for
  polyipseity, disabled for other users. Each user can provision their own
  repos using their GitHub username via the Home Manager dev-repos module.
  False skips provisioning without error.

.PARAMETER EnableVsCodeWorkspaceTrustParity
  Enable managed VS Code workspace trust for %USERPROFILE%\dev.  Writes the
  trust entry directly to state.vscdb via Bun's built-in bun:sqlite module so
  the folder opens without a trust prompt.  False skips the write; no cleanup
  is needed because VS Code manages its own trust DB state.

.PARAMETER NoAISync
  When specified, suppresses the post-apply Ollama model sync step.  Useful in
  CI or on low-bandwidth connections where model pulls (2-20 GB each) are
  undesirable.

.PARAMETER ReplicaSync
  When specified, runs the post-apply cloud replica sync step.  By default
  apply skips replica sync to avoid long blocking runs; a scheduled daily sync
  already converges replicas.

.PARAMETER VMSetup
  When specified, runs the post-apply VM provisioning step to create QCOW2
  disk images and QEMU start scripts for VMs declared in src/modules/VMs.json.
  Skipped by default because disk pre-allocation is slow and only required on
  the first provision of a new machine.
.PARAMETER MinFreeDiskGB
  Minimum free space threshold (GiB) used by the pre-flight health check.

.PARAMETER Help
  When present, prints this help text and exits without applying anything.

.EXAMPLE
  # Apply with explicit module directory and user list:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin')

.EXAMPLE
  # Apply only the user-level DSC file:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -ConfigFiles @('user/wallpaper.dsc.yml')

.EXAMPLE
  # Apply while explicitly scoping secret materialization to one user:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -PrimaryUsername 'admin'

.EXAMPLE
  # Apply while skipping the post-apply Ollama model sync:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -NoAISync

.EXAMPLE
  # Apply and opt in to immediate post-apply replica sync:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -ReplicaSync

.EXAMPLE
  # Apply while disabling machine age key auto-registration in .sops.yaml:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -EnableHostAgeKeyRegistration:$false

.EXAMPLE
  # Apply while disabling managed VS Code settings parity (cleanup only):
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin') -EnableVsCodeSettingsParity:$false

.EXAMPLE
  # Apply while disabling managed remote-access parity (cleanup only):
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\Windows\modules" -Users @('admin', 'guest') -EnableRemoteAccessParity:$false

.NOTES
  Environment variables:
    NUCLEUS_REPO_ROOT   Path to the nucleus repository root (auto-detected from script path).
    NUCLEUS_HOST   Must be set to "Windows" for apply behavior.
    USERNAME       Current Windows username.
    HOME           User home directory.
    LOCALAPPDATA   Local application data path.
    ProgramData    System-wide application data path.
    ProgramFiles   System program files path.
    USERPROFILE    User profile directory.

  Exit codes:
    0 on success; 1 on error.
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = $PSScriptRoot,
  [string[]]$ConfigFiles = @("system/env.dsc.yml", "system/scheduler.dsc.yml", "system/developer-mode.dsc.yml", "system/firewall.dsc.yml", "system/taskbar.dsc.yml", "system/computer-name.dsc.yml", "system/long-paths.dsc.yml", "system/storage-sense.dsc.yml", "system/font-substitutes.dsc.yml", "system/remote-desktop.dsc.yml", "system/packages.dsc.yml"),
  [Alias("h")]
  [switch]$Help,
  [Parameter(Mandatory)]
  [string]$ModuleDir,
  [string]$PrimaryUsername = [System.Environment]::UserName,
  [Parameter(Mandatory)]
  [string[]]$Users,
  [switch]$NoOptionalParity,
  [switch]$NoSecretsParity,
  [switch]$NoUserStateParity,
  [switch]$NoSystemParity,
  [int]$MinFreeDiskGB = 10,
  [switch]$NoAISync,
  [switch]$ReplicaSync,
  [switch]$VMSetup,
  [switch]$Elevated,
  [string]$ParamsJson = ""
)

$ErrorActionPreference = "Stop"

# If -ParamsJson was provided (by self-elevation), deserialize all parameters
# from the temp JSON file instead of from command-line arguments.
if ($ParamsJson -and (Test-Path $ParamsJson)) {
  $p = Get-Content $ParamsJson -Raw | ConvertFrom-Json
  $ConfigDir = $p.ConfigDir
  $ConfigFiles = [string[]]$p.ConfigFiles
  $ModuleDir = $p.ModuleDir
  $Users = [string[]]$p.Users
  $PrimaryUsername = $p.PrimaryUsername
  $NoOptionalParity = [bool]$p.NoOptionalParity
  $NoSecretsParity = [bool]$p.NoSecretsParity
  $NoUserStateParity = [bool]$p.NoUserStateParity
  $NoSystemParity = [bool]$p.NoSystemParity
  $MinFreeDiskGB = [int]$p.MinFreeDiskGB
  $NoAISync = [bool]$p.NoAISync
  $ReplicaSync = [bool]$p.ReplicaSync
  $VMSetup = [bool]$p.VMSetup
  $Elevated = $true
}

# Refuse to run as Administrator — privilege escalation is managed internally
# when needed rather than relying on an already-elevated caller.
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin -and -not $Elevated) {
  Write-Error "This script must not be run as Administrator. Run as a regular user (elevation is managed internally when needed)."
  exit 1
}

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

# Compose internal Enable-* flags from high-level -No* switches for downstream guards.
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
$EnableBunParity = -not $noUserStateParity
$EnableCloudDrivesParity = -not $noUserStateParity
$EnableCustomProvisionSymlinkParity = -not $noUserStateParity
$EnableGitSshParity = -not $noUserStateParity
$EnablePicardParity = -not $noUserStateParity
$EnableObsidianParity = -not $noUserStateParity
$EnableQtPassParity = -not $noUserStateParity
$EnableShellParity = -not $noUserStateParity
$EnableDevDirectoryParity = -not $noUserStateParity
$EnableDiscordMusicRPCParity = -not $noUserStateParity
$EnableCamillaDSPServiceParity = -not $noUserStateParity
$EnableCamillaDSPHeartbeatServiceParity = -not $noUserStateParity
$EnableCamillaGUIServiceParity = -not $noUserStateParity
$EnableSteamAutoStartupParity = -not $noUserStateParity
# EnableDevReposParity defaults to $null (deferred to devRepos registry).
# When user-state is skipped, force $false instead.
$EnableDevReposParity = if ($noUserStateParity) { $false } else { $null }
$EnableVsCodeExtensionsParity = -not $noUserStateParity
$EnableVsCodeSettingsParity = -not $noUserStateParity
$EnableVsCodeWorkspaceTrustParity = -not $noUserStateParity

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$secretsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "secrets"
$systemModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "system"
$setupModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "setup"
$userModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "user"
$editorsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "editors"
$wallpapersModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "wallpapers"

# ── Self-elevation ──────────────────────────────────────────────────────────────
# Match the POSIX model: non-admin caller → internal elevation → all subsequent
# operations execute with admin privileges.  No fallback code for "not admin" is
# needed after this point.
if (-not $Elevated) {
  $params = @{
    ConfigDir        = $ConfigDir
    ConfigFiles      = $ConfigFiles
    ModuleDir        = $ModuleDir
    Users            = $Users
    PrimaryUsername   = $PrimaryUsername
    NoOptionalParity  = $NoOptionalParity
    NoSecretsParity   = $NoSecretsParity
    NoUserStateParity = $NoUserStateParity
    NoSystemParity    = $NoSystemParity
    MinFreeDiskGB     = $MinFreeDiskGB
    NoAISync         = $NoAISync
    ReplicaSync      = $ReplicaSync
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
  Remove-Item $paramsJsonPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: same — temp file in %TEMP%; child may have already cleaned up
  exit $exitCode
}

# Managed PATH data: canonical list of user-scope bin directories.
# Must be loaded before any Sync-* or Invoke-* module that references
# $nucleusPathComponents, $nucleusPrependRegistry, or Get-NucleusManagedBinDir.
. (Join-Path -Path $resolvedModuleDir -ChildPath "ManagedPaths.ps1")

# Root utilities: shared helpers with no single domain affinity.
. (Join-Path -Path $resolvedModuleDir -ChildPath "Load-UserRegistry.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Invoke-LogManagement.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Resolve-Executable.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Test-ArchivingStack.ps1")
. (Join-Path -Path $resolvedModuleDir -ChildPath "Test-PrimaryUser.ps1")
# secrets/: decryption, SOPS age key management, and secret materialization.
# ConvertFrom-SshEd25519PublicKeyToAgePubKey must be loaded before any file that
# calls it (Register-HostAgeKey, Invoke-SecretVerification).
. (Join-Path -Path $secretsModuleDir -ChildPath "ConvertFrom-SshEd25519PublicKeyToAgePubKey.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Get-DecryptedBlob.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Get-Secret.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Invoke-JITSecretMaterialization.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Invoke-SecretVerification.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Register-HostAgeKey.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Remove-ManagedSecret.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Sync-Secret.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Sync-SecretFile.ps1")
. (Join-Path -Path $secretsModuleDir -ChildPath "Sync-UserSecret.ps1")
# system/: machine-level services and infrastructure (WinGet, SSH host, RDP, power, AI).
. (Join-Path -Path $systemModuleDir -ChildPath "Initialize-SSHHostKey.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-AISync.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-ReplicaSync.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-VMSetup.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-AgentHostShellSetup.ps1")
. (Join-Path -Path \$systemModuleDir -ChildPath "Invoke-EnsureLogDir.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "ConvertFrom-WingetLockfileToDsc.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-WingetConfiguration.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-CaddyLocalCA.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-JellyfinAccount.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-JellyfinLibrary.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-CaddyService.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-LiteLLMService.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-ReplicaSyncScheduledTask.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-OpenSSHServer.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-PowerPolicy.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-WifiMacRandomization.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-TerminalActivations.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-WindowsRDP.ps1")
# setup/: one-time or infrequent toolchain provisioning (Scoop, Bun, Cargo, prek, PowerShell modules).
. (Join-Path -Path $setupModuleDir -ChildPath "Initialize-DevDirectory.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Install-PrekHook.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-BunSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CamillaDSPSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CamillaGUISetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CargoBinstallSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-PowerShellModuleSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-RustupSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-ScoopSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-SourceBuild.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-UvSetup.ps1")
# user/: per-user home convergence (git/SSH, shell, agents, dev repos, apps).
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CloudDrive.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsClawHubSkill.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsSkill.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CustomProvisionSymlink.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DevRepo.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DiscordMusicRPC.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaDSPService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaDSPHeartbeatService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-CamillaGUIService.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Disable-SteamAutoStartup.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-GitAndSshConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ObsidianConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-PicardConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-QtPassConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-BunConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-UvConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ShellProfile.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-NextestConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DirenvConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-StarshipConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-UserPath.ps1")
# editors/: VS Code configuration and workspace management.
. (Join-Path -Path $editorsModuleDir -ChildPath "Set-VSCodeWorkspaceTrust.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeExtension.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeSetting.ps1")
. (Join-Path -Path $editorsModuleDir -ChildPath "Sync-VSCodeConfig.ps1")
# wallpapers/: wallpaper materialization and stale-file cleanup.
. (Join-Path -Path $wallpapersModuleDir -ChildPath "Remove-StaleWallpaper.ps1")
. (Join-Path -Path $wallpapersModuleDir -ChildPath "Sync-Wallpaper.ps1")
$healthCheckScript = Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\scripts\health-check.ps1"
if (Test-Path -Path $healthCheckScript) {
  & $healthCheckScript -MinFreeGB $MinFreeDiskGB -NoSecretHealth
}

# Load the user registry from src/hosts/Windows/users.json. This declarative
# configuration defines all users managed by this Windows host (primary and
# secondary) and mirrors the Nix users/default.nix module structure. Validate
# that all users in -Users parameter are registered in this registry.
$userRegistryPath = Join-Path -Path $PSScriptRoot -ChildPath "users.json"
$userRegistry = & (Join-Path -Path $resolvedModuleDir -ChildPath "Load-UserRegistry.ps1") -RegistryPath $userRegistryPath
$registeredUserNames = @($userRegistry.users.name)
$selectedUserRecords = @($userRegistry.users | Where-Object { $Users -contains $_.name })

# Validate that all explicitly provided users exist in the registry.
foreach ($user in $Users) {
  if ($user -notin $registeredUserNames) {
    Write-Error "User '$user' not found in registry. Registered users: $($registeredUserNames -join ', ')" -ErrorAction Stop
    exit 1
  }
}

# Build effective DSC file list from explicit -ConfigFiles plus optional
# per-user extensions declared in users.json (`dscConfigFiles`).  This keeps
# DSC selection declarative and user-scoped while preserving the canonical
# system/user baseline defaults.
$effectiveConfigFiles = @($ConfigFiles)
foreach ($configuredUser in $userRegistry.users) {
  if ($configuredUser.name -notin $Users) {
    continue
  }

  foreach ($userConfigFile in @($configuredUser.dscConfigFiles)) {
    if ([string]::IsNullOrWhiteSpace($userConfigFile)) {
      continue
    }
    # Prevent path traversal: entries must be plain filenames relative to user/.
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
  Write-Error "No primary user marked (isPrimary=true) in user registry" -ErrorAction Stop
  exit 1
}

$resolvedConfigDir = (Resolve-Path -Path $ConfigDir).Path
$machineSshHostKeyPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key"
$primarySshKeyPath = Join-Path -Path $HOME -ChildPath ".ssh\ssh_personal_$PrimaryUsername"

# Resolve managed executables before running any decryption/materialization.
# check-suppress:suppression_doc: probe — SOPS WinGet package directory may not exist; $null check handles absence.
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
  # check-suppress:suppression_doc: probe whether gpg is on PATH; Get-Command throws when absent.
  (Get-Command -Name "gpg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# check-suppress:suppression_doc: probe — prek WinGet package directory may not exist; $null check handles absence.
$prekPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Packages\j178.Prek_*") -Directory -ErrorAction SilentlyContinue |
  Sort-Object -Property Name -Descending |
  Select-Object -First 1

$prekExecutableFromWinget = $null
if ($null -ne $prekPackageDir) {
  # check-suppress:suppression_doc: probe — prek executable may not be in expected location; $null check handles absence.
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
$prekExe = if ($prekCandidates.Count -gt 0) {
  Resolve-Executable -Name "prek" -CandidatePaths $prekCandidates
} else {
  $null
}

# Define shared path variables before any registration or pre-flight step so
# both Register-HostAgeKey and the pre-flight loop reference the same
# resolved paths without duplicate definitions later in the script.
$secretsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\secrets"
$wallpaperAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "..\..\assets\wallpapers"
$machineSshHostKeyPubPath = Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key.pub"
$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\")).Path
# Method 3 (merge) — QtPass shared settings JSON source of truth shared with
# POSIX activation. QtPass stores settings in platform-native stores
# (registry on Windows), so Method 1 (symlink) does not apply.  # Method 3 (merge)
$qtPassSettingsPath = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\qtpass\qtpass.json"
# Method 3 (merge) — Picard defaults INI merged via Sync-PicardConfig on Windows
$picardDefaultsPath = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\picard\Picard.ini"
$sopsYamlPath = Join-Path -Path $repoRoot -ChildPath ".sops.yaml"

# Expose the repo root to any subprocesses (e.g. DSC script resources) that
# may need to locate repo-relative files.  $env:NUCLEUS_REPO_ROOT is forwarded
# through to DSC and subsequent activation steps.
# Cross-reference: env-variable-scope.instructions.md
# Nix-side source of truth: src/modules/lib/env-catalog.nix
$env:NUCLEUS_REPO_ROOT = $repoRoot

# Process-level NUCLEUS_HOST for this run (subprocesses see it immediately).
# Persistence is handled by system/env.dsc.yml (Machine scope via DSC).
$env:NUCLEUS_HOST = "Windows"

# NUCLEUS_REPO_ROOT: set dynamically per-activation because the repo path
# varies by machine (clone location).  Storing it in DSC would bake in an
# absolute path, breaking portability.  Write directly to Machine scope
# (requires elevation — guaranteed by self-elevation above).
$existingRoot = [Environment]::GetEnvironmentVariable("NUCLEUS_REPO_ROOT", "Machine")
if ($existingRoot -ne $repoRoot) {
  [Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $repoRoot, "Machine")
  Write-Output "apply: set NUCLEUS_REPO_ROOT=$repoRoot (Machine scope)"
  if ([Environment]::GetEnvironmentVariable("NUCLEUS_REPO_ROOT", "User") -ne $null) {
    [Environment]::SetEnvironmentVariable("NUCLEUS_REPO_ROOT", $null, "User")
  }
}

# Ensure the SSH host key exists before age key registration.  On a fresh
# machine the key is absent until the OpenSSH Server service first starts;
# Initialize-SSHHostKey starts it briefly if the service is installed
# but the key has not yet been written.
if ($EnableHostAgeKeyRegistration) {
  Initialize-SSHHostKey -MachineSshHostKeyPath $machineSshHostKeyPath
}

# Auto-register this machine's age key in .sops.yaml if not already present.
# Must run before the pre-flight secret decryption check so that on the very
# first apply the machine can already decrypt its own SOPS-encrypted secrets.
if ($EnableHostAgeKeyRegistration) {
  Register-HostAgeKey `
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
  Get-Secret -FilePath $secretPath -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe | Out-Null
}

if ($EnableSecretsParity) {
  Sync-Secret -SecretsDir $secretsDir -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -Users $Users -SopsExe $sopsExe
  # Materialize per-user secrets from src/secrets/users-<username>.yml when present.
  # No-op when the file does not exist so bootstrap runs continue uninterrupted.
  Sync-UserSecret `
    -RepoRoot $repoRoot `
    -GpgExe $gpgExe `
    -HostKeyPath $machineSshHostKeyPath `
    -PrimarySshKeyPath $primarySshKeyPath `
    -SopsExe $sopsExe `
    -PrimaryUsername $PrimaryUsername
}
else {
  Remove-ManagedSecret -Users $Users
}

# Materialise system-level secrets (AI API keys) from src/secrets/system.yml
# into %ProgramData%\nucleus\secrets\ so the SYSTEM-native litellm SCM service
# can read them at startup.
$systemSecretsDir = Join-Path -Path $env:ProgramData -ChildPath "nucleus\secrets"
$null = New-Item -Path $systemSecretsDir -ItemType Directory -Force
$systemYmlPath = Join-Path -Path $secretsDir -ChildPath "system.yml"
if (Test-Path -Path $systemYmlPath -PathType Leaf) {
  $systemSecrets = Get-Secret -FilePath $systemYmlPath -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe
  foreach ($key in @('ai_openrouter_api_key', 'ai_opencode_go_api_key', 'ai_opencode_zen_api_key')) {
    $value = $systemSecrets.$key
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $keyFile = Join-Path -Path $systemSecretsDir -ChildPath $key
      $existing = if (Test-Path -Path $keyFile -PathType Leaf) { Get-Content -Path $keyFile -Raw -Encoding UTF8 }
      if ($existing -ne $value) {
        [System.IO.File]::WriteAllText($keyFile, $value, [System.Text.UTF8Encoding]::new($false))
      }
    }
  }
}

# Materialize decrypted wallpapers ahead of DSC so user/wallpaper.dsc.yml can resolve an
# explicit active wallpaper path deterministically.
$wallpaperOutputDir = Join-Path -Path $HOME -ChildPath "Pictures\wallpapers"

# Post-materialization health check: verify all SOPS files are decryptable by
# both the GPG and personal SSH age backends, and that managed artefacts exist.
# Mirrors the POSIX verifySecretDecryption Home Manager activation.
Invoke-SecretVerification `
  -GpgExe $gpgExe `
  -HostKeyPath $machineSshHostKeyPath `
  -PrimaryUsername $PrimaryUsername `
  -SecretsDir $secretsDir `
  -WallpaperAssetsDir $wallpaperAssetsDir

$activeWallpaperPath = Sync-Wallpaper -AssetsDir $wallpaperAssetsDir -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -Users $Users -SopsExe $sopsExe
Remove-StaleWallpaper -AssetsDir $wallpaperAssetsDir -OutputDir $wallpaperOutputDir

# Generate locked DSC from lockfile before applying.
$lockfilePath = Join-Path -Path $PSScriptRoot -ChildPath "..\..\lockfiles\lockfile.json"
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/scheduler.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/scheduler.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/developer-mode.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/developer-mode.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/firewall.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/firewall.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/taskbar.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/taskbar.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/computer-name.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/computer-name.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/long-paths.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/long-paths.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/storage-sense.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/storage-sense.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/font-substitutes.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/font-substitutes.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/remote-desktop.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/remote-desktop.locked.dsc.yml")
ConvertFrom-WingetLockfileToDsc -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/packages.dsc.yml") -LockfilePath $lockfilePath -OutputPath (Join-Path -Path $resolvedConfigDir -ChildPath "system/packages.locked.dsc.yml")

# Replace system DSC files with locked variants in effective config list.
$effectiveConfigFiles = @($effectiveConfigFiles | ForEach-Object {
  if ($_ -eq "system/scheduler.dsc.yml") { "system/scheduler.locked.dsc.yml" }
  elseif ($_ -eq "system/developer-mode.dsc.yml") { "system/developer-mode.locked.dsc.yml" }
  elseif ($_ -eq "system/firewall.dsc.yml") { "system/firewall.locked.dsc.yml" }
  elseif ($_ -eq "system/taskbar.dsc.yml") { "system/taskbar.locked.dsc.yml" }
  elseif ($_ -eq "system/computer-name.dsc.yml") { "system/computer-name.locked.dsc.yml" }
  elseif ($_ -eq "system/long-paths.dsc.yml") { "system/long-paths.locked.dsc.yml" }
  elseif ($_ -eq "system/storage-sense.dsc.yml") { "system/storage-sense.locked.dsc.yml" }
  elseif ($_ -eq "system/font-substitutes.dsc.yml") { "system/font-substitutes.locked.dsc.yml" }
  elseif ($_ -eq "system/remote-desktop.dsc.yml") { "system/remote-desktop.locked.dsc.yml" }
  elseif ($_ -eq "system/packages.dsc.yml") { "system/packages.locked.dsc.yml" }
  else { $_ }
})

foreach ($configFile in $effectiveConfigFiles) {
  Invoke-WingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile) -WallpaperPath $activeWallpaperPath
}

# Set Windows Application Event Log max size to 200 MB.
# No declarative DSC resource exists for this; wevtutil is the canonical tool.
wevtutil sl Application /ms:209715200 2>$null  # check-suppress:suppression_doc: may already be at desired size; wevtutil exits non-zero but this is harmless

# Scoop bucket and app provisioning must run after DSC installs Scoop.Scoop.
# scoop shims are written to a user-local directory that is not on PATH in
# the current session until explicitly prepended; Invoke-ScoopSetup handles
# that prepend internally.
# rustup toolchain management runs after WinGet DSC has installed Rustlang.Rustup.
# Must run before Invoke-CargoBinstallSetup so the stable toolchain (and its
# cargo binary) are available for compilation fallback.
Invoke-RustupSetup
Invoke-ScoopSetup
# cargo-binstall managed packages run after Invoke-ScoopSetup has installed
# cargo-binstall from Scoop and prepended the shims directory to PATH.
Invoke-CargoBinstallSetup
# bun global packages run after WinGet DSC has installed Oven-sh.Bun.
# bun-setup prepends ~/.bun/bin to PATH internally for this session.
if ($EnableBunParity) {
  Invoke-BunSetup
}
# uv global tools run after WinGet DSC has installed astral-sh.uv.
# uv-setup prepends ~/.local/bin to PATH internally for this session.
Invoke-UvSetup
# PowerShell modules: pinned versions for DSC validation and code hygiene.
Invoke-PowerShellModuleSetup
# CamillaDSP prebuilt binary runs after PATH is fully configured (no WinGet
# package available; downloads from GitHub releases).
Invoke-CamillaDSPSetup
# camillagui-backend prebuilt bundle (same rationale as CamillaDSP).
Invoke-CamillaGUISetup
# Source-built packages: git clone + build system at pinned revisions.
# Requires zig from Scoop (installed by Invoke-ScoopSetup above) and
# git from WinGet (system/packages.dsc.yml).
Invoke-SourceBuild

# Ensure the live nucleus checkout installs its own Git hooks during the same
# provision run that installs or updates prek itself.
Install-PrekHook -PrekExecutablePath $prekExe -RepositoryRoot $repoRoot

# Build dev repositories list from user registry, resolving symlink targets.
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

    # Resolve symlink: if marked as symlinkFromRepoRoot, target is $repoRoot
    if ($repo.symlinkFromRepoRoot) {
      $repoEntry.symlink = $repoRoot
    }
    elseif ($repo.url) {
      $repoEntry.url = $repo.url
    }

    $devRepositories += $repoEntry
  }
}

Sync-AgentsConfig -RepoRoot $repoRoot -Enabled:$EnableAgentsConfigParity
Sync-AgentsSkill -RepoRoot $repoRoot -Enabled:$EnableAgentsSkillsParity
Sync-AgentsClawHubSkill -RepoRoot $repoRoot -Enabled:$EnableAgentsClawHubSkillsParity
Sync-VSCodeConfig -RepoRoot $repoRoot -Enabled:$EnableVsCodeSettingsParity -Username $Users[0]
Sync-VSCodeExtension -Enabled:$EnableVsCodeExtensionsParity
Initialize-DevDirectory -Enabled:$EnableDevDirectoryParity
Set-VSCodeWorkspaceTrust -Enabled:$EnableVsCodeWorkspaceTrustParity
Sync-GitAndSshConfig -Enabled:$EnableGitSshParity -Users $Users
Sync-ObsidianConfig -Enabled:$EnableObsidianParity -Users $selectedUserRecords
Sync-PicardConfig -Enabled:$EnablePicardParity -Users $selectedUserRecords -DefaultsFilePath $picardDefaultsPath
Sync-QtPassConfig -Enabled:$EnableQtPassParity -SettingsPath $qtPassSettingsPath -Users $selectedUserRecords
# Default to false if devReposEnabled not yet set (user not in registry or no repos configured).
if ($null -eq $EnableDevReposParity) {
  $EnableDevReposParity = $devReposEnabled
}

# Keep dev repo provisioning after Git/SSH config so clones see the same
# secret/key ordering across macOS, NixOS, and Windows.
Sync-DevRepo -Enabled:$EnableDevReposParity -Repositories $devRepositories
Sync-ShellProfile -Enabled:$EnableShellParity
# Method 1 (writable symlink): bun and uv configs symlinked to repo files.
Sync-BunConfig -Enabled:$EnableShellParity
Sync-UvConfig -Enabled:$EnableShellParity
Sync-NextestConfig -Enabled:$EnableShellParity
# Method 1 (writable symlink): direnvrc cross-platform base config.
Sync-DirenvConfig -Enabled:$EnableShellParity
Sync-StarshipConfig -Enabled:$EnableShellParity
if ($EnableCloudDrivesParity) {
  foreach ($userRecord in $selectedUserRecords) {
    Sync-CloudDrive -UserConfig $userRecord -HomeDirectory $userRecord.homeDirectory
  }
}
# Ensure all nucleus log subdirectories exist before starting services.
Invoke-EnsureLogDir -ServicesJson (Join-Path -Path $repoRoot -ChildPath "src\modules\services.json")
Sync-CaddyService -RepoRoot $repoRoot -Enabled:`$true
Sync-CaddyLocalCA -RepoRoot $repoRoot -Enabled:$true
Sync-JellyfinAccount -RepoRoot $repoRoot -UserRecords $selectedUserRecords -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe
Sync-JellyfinLibrary -RepoRoot $repoRoot -UserRecords $selectedUserRecords -GpgExe $gpgExe -HostKeyPath $machineSshHostKeyPath -PrimarySshKeyPath $primarySshKeyPath -SopsExe $sopsExe
Sync-CustomProvisionSymlink -Enabled:$EnableCustomProvisionSymlinkParity -UserRecords $selectedUserRecords
# Method 1 (writable symlink): symlink config so edits take effect immediately.
  $discordMusicRPCConfigDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "discord-music-rpc"
  $null = New-Item -Path $discordMusicRPCConfigDir -ItemType Directory -Force
  $discordMusicRPCConfig = Join-Path -Path $discordMusicRPCConfigDir -ChildPath "config.yaml"
  $discordMusicRPCConfigSource = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\discord-music-rpc\config.yaml"
  if (Test-Path -Path $discordMusicRPCConfig) { Remove-Item -Path $discordMusicRPCConfig -Force }
  New-Item -Path $discordMusicRPCConfig -ItemType SymbolicLink -Target $discordMusicRPCConfigSource -Force | Out-Null
Sync-DiscordMusicRPC -Enabled:$EnableDiscordMusicRPCParity
Sync-CamillaDSPService -Enabled:$EnableCamillaDSPServiceParity
Sync-CamillaDSPHeartbeatService -Enabled:$EnableCamillaDSPHeartbeatServiceParity
Sync-CamillaGUIService -Enabled:$EnableCamillaGUIServiceParity
Disable-SteamAutoStartup -Enabled:$EnableSteamAutoStartupParity
Sync-LiteLLMService -RepoRoot $repoRoot -Enabled:`$true
Sync-ReplicaSyncScheduledTask -RepoRoot $repoRoot -Enabled:$EnableCloudDrivesParity
Sync-OpenSSHServer -Enabled:$EnableRemoteAccessParity
# Re-run host age key registration after Sync-OpenSSHServer has started
# the sshd service (which generates host keys on a fresh machine).  This second
# call is a no-op when the key is already registered; on first-ever apply it
# completes registration in the same run without requiring a second apply.
if ($EnableHostAgeKeyRegistration) {
  Register-HostAgeKey `
    -MachineSshHostKeyPubPath $machineSshHostKeyPubPath `
    -SopsExe $sopsExe `
    -SopsYamlPath $sopsYamlPath `
    -SecretsDir $secretsDir `
    -WallpaperAssetsDir $wallpaperAssetsDir
}
Sync-WindowsRDP -Enabled:$EnableRdpParity
Sync-PowerPolicy -Enabled:$EnablePowerParity
Sync-UserPath -Enabled:$EnableShellParity
Sync-WifiMacRandomization -Enabled:$EnableWiFiParity
Sync-TerminalActivations
# WHY terminal-activations (last resort): this stage runs in the user's
# terminal context (outside the Nix rebuild) for macOS TCC-sensitive commands.
# On Windows the manifest is absent by default (no TCC constraints), but the
# mechanism is shared cross-platform.  See src/modules/terminal-activations.nix
# for the full policy.
Invoke-AgentHostShellSetup

# Warn-only service verification: check all managed services are running.
# Failing to start a service should not block activation, but the warning
# surfaces issues for post-apply investigation.
$svcScript = Join-Path -Path $repoRoot -ChildPath "scripts\svc.ps1"
if (Test-Path -LiteralPath $svcScript) {
  try {
    & $svcScript verify
  } catch {
    Write-NucleusWarning "svc: some services are inactive (non-fatal; check Event Viewer for details)"
  }
}

# Health check: verify archiving ecosystem (7-Zip CLI + app) is functional post-apply.
Test-ArchivingStack | Out-Null

# Converge locally installed Ollama models with the declarative manifest as the
# final step of every apply.  Model pulls are 2-20 GB, so this runs last to
# avoid blocking earlier configuration steps.  The sync is best-effort: a
# missing or unreachable ollama binary is informational, not a hard failure,
# because the system configuration has already been applied successfully.
if ($NoAISync) {
  Write-Output "ai: -NoAISync set; skipping post-apply model sync"
} else {
  # check-suppress:suppression_doc: probe whether ollama is installed (may not be on first-provision hosts).
  $ollamaOnPath = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaOnPath) {
    Write-Output "ai: ollama not found in PATH; skipping post-apply model sync"
  } else {
    Write-Output "ai: running post-apply AI model sync..."
    Invoke-AISync -RepoRoot $repoRoot -ServerReadyTimeoutSeconds 60
  }
}

# Converge enabled cloud replicas from users.json as the final post-apply step.
# This is best-effort: replica sync can be long-running and should not
# retroactively fail a completed configuration convergence.

if (-not $ReplicaSync) {
  Write-Output "replica-sync: skipping post-apply replica sync (default; pass -ReplicaSync to run now)"
} else {
  # check-suppress:suppression_doc: probe — rclone may be absent on first-provision hosts.
  $rcloneOnPath = Get-Command -Name "rclone" -ErrorAction SilentlyContinue
  if ($null -eq $rcloneOnPath) {
    Write-Output "replica-sync: rclone not found in PATH; skipping post-apply replica sync"
  } else {
    Write-Output "replica-sync: running post-apply replica sync..."
    try {
      Invoke-ReplicaSync -RepoRoot $repoRoot
    } catch {
      Write-Warning "replica-sync: replica sync incomplete (system apply succeeded): $($_.Exception.Message)"
    }
  }
}

# Provision VM disk images and QEMU start scripts for VMs declared in VMs.json.
# This is best-effort: a VM setup failure should not retroactively fail a
# completed configuration apply.
if (-not $VMSetup) {
  Write-Output "vm-setup: -VMSetup not set; skipping post-apply VM provisioning"
} else {
  Write-Output "vm-setup: running post-apply VM provisioning..."
  try {
    Invoke-VMSetup -RepoRoot $repoRoot
  } catch {
    Write-Warning "vm-setup: VM setup incomplete (system apply succeeded): $($_.Exception.Message)"
  }
}

# Perform bounded garbage collection as the final step after all provisioning.
# GC is best-effort: failures should not retroactively fail a completed apply.
# After all provisioning, GC can reclaim build artifacts, caches, and stale files.
$gcScript = Join-Path -Path $repoRoot -ChildPath "scripts\gc.ps1"
if (-not (Test-Path -LiteralPath $gcScript)) {
  Write-Output "gc: scripts/gc.ps1 not found; skipping garbage collection"
} else {
  Write-Output "gc: running post-apply garbage collection..."
  try {
    & $gcScript -ModuleDir $systemModuleDir -RepoRoot $repoRoot
  } catch {
    Write-Warning "gc: GC incomplete (system apply succeeded): $($_.Exception.Message)"
  }
}

# Display host-scoped one-time manual setup instructions as the final post-apply
# step so operators see the checklist with no intervening output.
$manualPath = Join-Path -Path $PSScriptRoot -ChildPath "MANUAL.md"
Write-Output "--- MANUAL SETUP (one-time, required) ---"
Get-Content -Path $manualPath | Write-Output
Write-Output "-------------------------------------------"
