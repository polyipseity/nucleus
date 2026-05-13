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
  @('system.dsc.yml', 'user.dsc.yml').  Filenames are resolved relative to
  $ConfigDir.

  Additional per-user DSC files can be declared in users.json under each
  user's dscConfigFiles array.  apply.ps1 appends those files for every user
  listed in -Users (de-duplicated, preserving order) so each managed user can
  extend the declarative DSC set without editing script code.

.PARAMETER ModuleDir
  Path to the directory containing one-function Windows helper modules.
  Mandatory: caller must explicitly pass the module directory so they are
  aware of which modules will be loaded and executed.

.PARAMETER PrimaryUsername
  Username allowed to materialize user-scoped secrets. Defaults to the
  current interactive user for legacy compatibility, but -Users is the
  preferred way to specify configured users. Deprecated: use -Users instead.

.PARAMETER Users
  Array of usernames to configure. Mandatory: each user in this list gets
  their secrets materialized, SSH keys adopted, and home directory state
  converged. Callers must explicitly pass this list so they are aware of
  which user profiles will be modified. The first user in the list is used
  for secrets materialization.
  Example: -Users @('admin', 'guest')

  Note: For full multi-user support where each user gets their own secrets,
  SSH keys, and home directory state, run apply.ps1 separately for each user:
    .\apply.ps1 -ModuleDir "C:\path\to\src\hosts\windows\modules" -Users @('admin')
    .\apply.ps1 -ModuleDir "C:\path\to\src\hosts\windows\modules" -Users @('guest')
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

.PARAMETER EnableGitSshParity
  Enable managed user-level Git/SSH parity convergence and block cleanup logic.

.PARAMETER EnableHostAgeKeyRegistration
  Register this machine's SSH host public key as an age recipient in .sops.yaml
  and rewrap all SOPS-encrypted files on first apply.  Idempotent: no-op when
  the key is already registered.  Disable to skip registration (e.g. on
  machines where the SSH host key is not yet a designated SOPS recipient).

.PARAMETER EnablePowerParity
  Enable managed Windows power policy parity convergence and cleanup fallback.

.PARAMETER EnableObsidianParity
  Enable managed Obsidian advanced-settings parity convergence and cleanup
  fallback while preserving unmanaged vault metadata in the live app config.

.PARAMETER EnableQtPassParity
  Enable managed QtPass Settings/Template tab parity convergence and cleanup fallback.

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

.PARAMETER SkipAISync
  When specified, suppresses the post-apply Ollama model sync step.  Useful in
  CI or on low-bandwidth connections where model pulls (2-20 GB each) are
  undesirable.

.PARAMETER MinFreeDiskGB
  Minimum free space threshold (GiB) used by the pre-flight health check.

.PARAMETER Help
  When present, prints this help text and exits without applying anything.

.EXAMPLE
  # Apply with explicit module directory and user list:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin')

.EXAMPLE
  # Apply only the user-level DSC file:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin') -ConfigFiles @('user.dsc.yml')

.EXAMPLE
  # Apply while explicitly scoping secret materialization to one user:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin') -PrimaryUsername 'admin'

.EXAMPLE
  # Apply while skipping the post-apply Ollama model sync:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin') -SkipAISync

.EXAMPLE
  # Apply while disabling machine age key auto-registration in .sops.yaml:
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin') -EnableHostAgeKeyRegistration:$false

.EXAMPLE
  # Apply while disabling managed VS Code settings parity (cleanup only):
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin') -EnableVsCodeSettingsParity:$false

.EXAMPLE
  # Apply while disabling managed remote-access parity (cleanup only):
  .\apply.ps1 -ModuleDir "C:\Users\admin\nucleus\src\hosts\windows\modules" -Users @('admin', 'guest') -EnableRemoteAccessParity:$false
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = $PSScriptRoot,
  [string[]]$ConfigFiles = @("system.dsc.yml", "user.dsc.yml"),
  [switch]$Help,
  [Parameter(Mandatory)]
  [string]$ModuleDir,
  [string]$PrimaryUsername = [System.Environment]::UserName,
  [Parameter(Mandatory)]
  [string[]]$Users,
  [bool]$EnableAgentsConfigParity = $true,
  [bool]$EnableAgentsSkillsParity = $true,
  [bool]$EnableAgentsClawHubSkillsParity = $true,
  [bool]$EnableSecretsParity = $true,
  [bool]$EnableBunParity = $true,
  [bool]$EnableGitSshParity = $true,
  [bool]$EnableHostAgeKeyRegistration = $true,
  [bool]$EnablePowerParity = $true,
  [bool]$EnableObsidianParity = $true,
  [bool]$EnableQtPassParity = $true,
  [bool]$EnableRdpParity = $true,
  [bool]$EnableRemoteAccessParity = $true,
  [bool]$EnableShellParity = $true,
  [bool]$EnableDevDirectoryParity = $true,
  [bool]$EnableDevReposParity = $null,
  [bool]$EnableVsCodeExtensionsParity = $true,
  [bool]$EnableVsCodeSettingsParity = $true,
  [bool]$EnableVsCodeWorkspaceTrustParity = $true,
  [int]$MinFreeDiskGB = 10,
  [switch]$SkipAISync
)

$ErrorActionPreference = "Stop"
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$resolvedModuleDir = (Resolve-Path -Path $ModuleDir).Path
$secretsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "secrets"
$systemModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "system"
$setupModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "setup"
$userModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "user"
$editorsModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "editors"
$wallpapersModuleDir = Join-Path -Path $resolvedModuleDir -ChildPath "wallpapers"
# Root utilities: shared helpers with no single domain affinity.
. (Join-Path -Path $resolvedModuleDir -ChildPath "Load-UserRegistry.ps1")
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
# system/: machine-level services and infrastructure (WinGet, SSH host, RDP, power, AI).
. (Join-Path -Path $systemModuleDir -ChildPath "Initialize-SSHHostKey.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-AISync.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Invoke-WingetConfiguration.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-OpenSshServer.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-PowerPolicy.ps1")
. (Join-Path -Path $systemModuleDir -ChildPath "Sync-WindowsRdp.ps1")
# setup/: one-time or infrequent toolchain provisioning (Scoop, Bun, Cargo, prek).
. (Join-Path -Path $setupModuleDir -ChildPath "Initialize-DevDirectory.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Install-PrekHook.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-BunSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-CargoBinstallSetup.ps1")
. (Join-Path -Path $setupModuleDir -ChildPath "Invoke-ScoopSetup.ps1")
# user/: per-user home convergence (git/SSH, shell, agents, dev repos, apps).
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsClawHubSkill.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-AgentsSkill.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-DevRepo.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-GitAndSshConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ObsidianConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-QtPassConfig.ps1")
. (Join-Path -Path $userModuleDir -ChildPath "Sync-ShellProfile.ps1")
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
  & $healthCheckScript -MinFreeGB $MinFreeDiskGB -SkipSecretTooling
}

# Load the user registry from src/hosts/windows/users.json. This declarative
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
    if ($userConfigFile -notin $effectiveConfigFiles) {
      $effectiveConfigFiles += $userConfigFile
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

$prekPackageDir = Get-ChildItem -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\WinGet\Packages\j178.Prek_*") -Directory -ErrorAction SilentlyContinue |
  Sort-Object -Property Name -Descending |
  Select-Object -First 1

$prekExecutableFromWinget = $null
if ($null -ne $prekPackageDir) {
  $prekExecutableFromWinget = Get-ChildItem -Path $prekPackageDir.FullName -Filter "prek*.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object -Property FullName |
    Select-Object -First 1 -ExpandProperty FullName
}

$prekCandidates = @(
  $prekExecutableFromWinget,
  (Get-Command -Name "prek.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
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
$qtPassSettingsPath = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\qtpass\settings.json"
$sopsYamlPath = Join-Path -Path $repoRoot -ChildPath ".sops.yaml"

# Expose the repo root to any subprocesses (e.g. DSC script resources) that
# may need to locate repo-relative files.  Also write it to a stable file path
# so Home Manager activation scripts (e.g. vscodeSymlinks in editors.nix) can
# read it after the sudo boundary that darwin-rebuild/nixos-rebuild crosses,
# where environment variables are not reliably propagated.
$env:NUCLEUS_REPO = $repoRoot
$configDir = Join-Path -Path $HOME -ChildPath ".config\nucleus"
  if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
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
}
else {
  Remove-ManagedSecret -Users $Users
}

# Materialize decrypted wallpapers ahead of DSC so user.dsc.yml can resolve an
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

foreach ($configFile in $effectiveConfigFiles) {
  Invoke-WingetConfiguration -ConfigPath (Join-Path -Path $resolvedConfigDir -ChildPath $configFile) -WallpaperPath $activeWallpaperPath
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
Sync-QtPassConfig -Enabled:$EnableQtPassParity -SettingsPath $qtPassSettingsPath -Users $selectedUserRecords
# Default to false if devReposEnabled not yet set (user not in registry or no repos configured).
if ($null -eq $EnableDevReposParity) {
  $EnableDevReposParity = $devReposEnabled
}

# Keep dev repo provisioning after Git/SSH config so clones see the same
# secret/key ordering across macOS, NixOS, and Windows.
Sync-DevRepo -Enabled:$EnableDevReposParity -Repositories $devRepositories
Sync-ShellProfile -Enabled:$EnableShellParity
Sync-OpenSshServer -Enabled:$EnableRemoteAccessParity
# Re-run host age key registration after Sync-OpenSshServer has started
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
Sync-WindowsRdp -Enabled:$EnableRdpParity
Sync-PowerPolicy -Enabled:$EnablePowerParity

# Health check: verify archiving ecosystem (7-Zip CLI + app) is functional post-apply.
Test-ArchivingStack | Out-Null

# Display host-scoped one-time manual setup instructions after all main
# convergence is complete but before post-apply tasks (like AI model downloads)
# so operators see the checklist while configuration is still in their context,
# mirroring the displayHostManualInstructions activation on macOS and NixOS hosts.
$manualPath = Join-Path -Path $PSScriptRoot -ChildPath "MANUAL.md"
Write-Output "--- MANUAL SETUP (one-time, required) ---"
Get-Content -Path $manualPath | Write-Output
Write-Output "-------------------------------------------"

# Converge locally installed Ollama models with the declarative manifest as the
# final step of every apply.  Model pulls are 2-20 GB, so this runs last to
# avoid blocking earlier configuration steps.  The sync is best-effort: a
# missing or unreachable ollama binary is informational, not a hard failure,
# because the system configuration has already been applied successfully.
if ($SkipAISync) {
  Write-Output "AI-sync: -SkipAISync set; skipping post-apply model sync"
} else {
  $ollamaOnPath = Get-Command -Name "ollama" -ErrorAction SilentlyContinue
  if ($null -eq $ollamaOnPath) {
    Write-Output "AI-sync: ollama not found in PATH; skipping post-apply model sync"
  } else {
    Write-Output "AI-sync: running post-apply AI model sync..."
    Invoke-AISync -RepoRoot $repoRoot -ServerReadyTimeoutSeconds 60
  }
}
