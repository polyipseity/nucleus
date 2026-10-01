<#
.SYNOPSIS
  Install bootstrap dependencies for the nucleus environment on Windows.

.DESCRIPTION
  Installs GnuPG (directly from the NSIS installer) and SOPS via winget using
  pinned versions from scripts/bootstrap-versions.env.

.PARAMETER ApplyArgs
  Optional arguments passed through to src/hosts/Windows/apply.ps1 (default: empty).
  Use -- before positional passthrough args (e.g., .\bootstrap.ps1 -Apply -- -DryRun).

.PARAMETER TargetUser
  Accepted for cross-platform CLI parity. Only effective on the POSIX apply
  path (nix run .#apply -- --target-user=<name>). On Windows this flag is
  accepted but ignored (default: none).

.NOTES
  Environment variables: NUCLEUS_APPLY, NUCLEUS_AI_SYNC, NUCLEUS_REPLICA_SYNC, NUCLEUS_TARGET_USER.
#>
[CmdletBinding()]
param(
  [Alias("a")]
  [Parameter()]
  [switch]$Apply = $(if ($env:NUCLEUS_APPLY -eq 'true') { $true } else { $false }),

  [Parameter(ValueFromRemainingArguments)]
  [string[]]$ApplyArgs,

  [Parameter()]
  [switch]$NoAISync = $(if ($env:NUCLEUS_AI_SYNC -eq 'false') { $true } else { $false }),

  [Parameter()]
  [switch]$ForceAdmin,

  [Parameter()]
  [switch]$ReplicaSync = $(if ($env:NUCLEUS_REPLICA_SYNC -eq 'true') { $true } else { $false }),

  [Parameter()]
  [string]$TargetUser = $(if ($env:NUCLEUS_TARGET_USER) { $env:NUCLEUS_TARGET_USER } else { '' }),

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# WHY refuse: elevation is managed internally when needed, so an already-elevated
# caller hides whether a step actually needs it.
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin -and -not $ForceAdmin) {
  Write-NucleusError "this script must not be run as Administrator. Run as a regular user (elevation is managed internally when needed)."
  exit 1
}

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
    Returns the trimmed value of $Key, throwing when it is absent or blank so a
    missing version pin cannot fail silently.

  .OUTPUTS
    [string] The non-empty value associated with $Key.
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

function Import-BootstrapVersionTable {
  <#
  .SYNOPSIS
    Parses a shell-compatible KEY=value env file into an ordered hashtable.

  .DESCRIPTION
    Reads $FilePath line by line and extracts KEY=value pairs using
    ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$. Comments and blank lines are skipped, outer
    quotes are stripped, and keys keep their original casing.

  .OUTPUTS
    [ordered hashtable] Parsed key/value pairs in file order.
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

function Invoke-WingetPackageInstall {
  <#
  .SYNOPSIS
    Installs or verifies a winget package at an optional pinned version.

  .DESCRIPTION
    Runs `winget install` with non-interactive flags. Exit code 0 and
    -1978335189 (WINGET_ERROR_NO_APPLICABLE_UPDATE) both return without
    throwing; any other code falls back to the latest available version, so a
    withdrawn pin degrades instead of failing.

  .PARAMETER Version
    Optional. Exact version string to install. When omitted, the latest
    available version is installed.
  #>
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- catch guards against terminating errors from Stop-Process when the process already exited; -ErrorAction SilentlyContinue handles the common case
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
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
    # WHY the winget source: msstore lacks the HashiCorp/SOPS packages and its
    # agreement prompt blocks source resolution on fresh CI runners.
    "--source"
    "winget"
  )

  # WHY 300s: a safety net for an install that hangs on a resident child process.
  # Ref: https://github.com/fleetdm/fleet/pull/50025
  $TimeoutSeconds = 300

  if ($Version) {
    $versionedArgs = @($installArgs + @("--version", $Version))
    $proc = Start-Process -FilePath "winget" -ArgumentList $versionedArgs `
      -PassThru -NoNewWindow
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      try {
        # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      } catch {
        # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
        $null = $null
      }
      throw "winget install for '$Id' (version $Version) timed out after $TimeoutSeconds seconds"
    }
    $LASTEXITCODE = $proc.ExitCode

    if ($LASTEXITCODE -eq 0) {
      return
    }

    if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
      Write-NucleusInfo "Package '$Id' is already installed at the requested version (or newer available version is not applicable)."
      return
    }

    Write-NucleusInfo "Requested version '$Version' for '$Id' not available. Falling back to latest."
  }

  $proc = Start-Process -FilePath "winget" -ArgumentList $installArgs `
    -PassThru -NoNewWindow
  if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try {
      # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {
      # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
      $null = $null
    }
    throw "winget install for '$Id' timed out after $TimeoutSeconds seconds"
  }
  $LASTEXITCODE = $proc.ExitCode

  if ($LASTEXITCODE -eq 0) {
    return
  }

  if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
    Write-NucleusInfo "Package '$Id' is already installed and up to date."
    return
  }

  throw "Failed to install package '$Id' with winget. Exit code: $LASTEXITCODE"
}

function Install-GnuPGDirect {
  <#
  .SYNOPSIS
    Installs GnuPG directly from the NSIS installer, bypassing winget.

  .DESCRIPTION
    winget --silent does not suppress the GpgEX regsvr32 dialog on headless CI,
    and the NSIS installer blocks on a modal MessageBox even with /S (no /SD
    default). The installer's own MainWindowHandle is polled and closed after a
    grace period; success is verified through the Add/Remove Programs entry,
    which inst.nsi writes in its last hidden section, so the exit code alone is
    unreliable on the timeout path.

    Ref: https://github.com/fleetdm/fleet/pull/50025
    Ref: https://github.com/fleetdm/fleet/commit/5326bed
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$InstallerDate,

    [Parameter(Mandatory = $true)]
    [string]$InstallerSha256
  )

  $installDir = Join-Path ${env:ProgramFiles} 'GnuPG'
  $gpgExe = Join-Path $installDir 'gpg.exe'

  if (Test-Path -Path $gpgExe -PathType Leaf) {
    $installedVersion = & $gpgExe --version 2>&1 | Select-Object -First 1
    if ($installedVersion -match [regex]::Escape($Version)) {
      Write-NucleusInfo "GnuPG $Version is already installed at $installDir."
      return
    }
  }

  $installerName = "gnupg-w32-${Version}_${InstallerDate}.exe"
  $installerUrl = "https://gnupg.org/ftp/gcrypt/binary/$installerName"
  $tempDir = Join-Path $env:TEMP "gnupg-install-$Version"
  $installerPath = Join-Path $tempDir $installerName

  if (-not (Test-Path -Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force > $null
  }

  Write-NucleusInfo "Downloading GnuPG $Version from $installerUrl"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    $webClient = [System.Net.WebClient]::new()
    $webClient.DownloadFile($installerUrl, $installerPath)
  } catch {
    throw "Failed to download GnuPG installer from $installerUrl : $_"
  }

  $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
  if ($actualHash -ne $InstallerSha256) {
    throw "GnuPG installer hash mismatch: expected $InstallerSha256, got $actualHash"
  }

  # WHY the window polling: the GnuPG NSIS installer calls RegDLL on gpgex6.dll,
  # and on headless CI regsvr32 fails and opens a modal MessageBox with no /SD
  # default that /S does not suppress. The dialog belongs to the installer
  # process itself, not to regsvr32/gpgex children (Fleet 5326bed).
  Write-NucleusInfo "Installing GnuPG $Version to $installDir"
  $proc = Start-Process -FilePath $installerPath -ArgumentList "/S", "/D=$installDir" -PassThru -NoNewWindow
  $TimeoutSeconds = 420
  $pollSeconds = 10
  $graceSeconds = 30
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $graceDeadline = (Get-Date).AddSeconds($graceSeconds)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $pollSeconds
    $proc.Refresh()
    if ($proc.HasExited) { break }

    if ((Get-Date) -gt $graceDeadline -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
      Write-NucleusInfo "Closing installer dialog window ('$($proc.MainWindowTitle)')"
      # check-suppress:suppression_doc: return value discarded; close is best-effort
      $null = $proc.CloseMainWindow()
    }
  }
  if (-not $proc.HasExited) {
    # Timeout — kill the installer and any leftover children.
    Write-NucleusInfo "Installer still running after ${TimeoutSeconds}s; stopping it."
    try {
      # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {
      # check-suppress:suppression_doc: process may already have exited
      $null = $null
    }
  } else {
    Write-NucleusInfo "Install exit code: $($proc.ExitCode)"
  }

  $daemons = @('gpg-agent', 'dirmngr', 'keyboxd', 'scdaemon', 'gpg-connect-agent', 'gpgme-w32spawn', 'gpa', 'launch-gpa')
  foreach ($daemon in $daemons) {
    # check-suppress:suppression_doc: daemon may not be running; best-effort stop
    Stop-Process -Name $daemon -Force -ErrorAction SilentlyContinue
  }

  # WHY the ARP entry: a killed installer (timeout path) has a meaningless exit
  # code, and inst.nsi writes the entry in its last hidden section.
  $arpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $arpKey32 = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $arpKeyUser = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  # check-suppress:suppression_doc: registry keys may not exist on all systems; probe is best-effort
  $registered = $null -ne (Get-ChildItem -Path @($arpKey, $arpKey32, $arpKeyUser) -ErrorAction SilentlyContinue |
    # check-suppress:suppression_doc: subkey may not exist or be accessible; probe is best-effort
    ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
    Where-Object { $_.DisplayName -like 'GNU Privacy Guard*' } |
    Select-Object -First 1)

  if (-not $registered) {
    throw 'GnuPG did not register in Add/Remove Programs after installation'
  }

  Write-NucleusInfo "GnuPG $Version installed successfully at $installDir"
}

function Invoke-RepositoryDirenvAllowIfAvailable {
  <#
  .SYNOPSIS
    Best-effort direnv allow for the canonical nucleus repository root.

  .DESCRIPTION
    Runs `direnv allow` only when direnv is available, `.envrc` exists, and the
    bootstrap repository root basename is exactly `nucleus`, which keeps
    auto-allow narrow and avoids trusting non-nucleus checkouts.

    Failures are warnings because direnv allow is convenience-only and must not
    block bootstrap or apply.
  #>
  [CmdletBinding()]
  param()

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not (Get-Command -Name direnv -ErrorAction SilentlyContinue)) {
    return
  }

  $repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).Path
  if ((Split-Path -Path $repoRoot -Leaf) -ne "nucleus") {
    return
  }

  $envrcPath = Join-Path -Path $repoRoot -ChildPath ".envrc"
  if (-not (Test-Path -Path $envrcPath -PathType Leaf)) {
    return
  }

  & direnv allow $repoRoot
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusWarning "failed to run 'direnv allow' for $repoRoot"
  }
}

function Install-Uv {
  <#
  .SYNOPSIS
    Installs uv if not already available.

  .DESCRIPTION
    Downloads and runs the official uv installer from astral.sh. uv is needed
    for the Python check tools (yamllint, check-jsonschema) that have no WinGet
    or Scoop package.
  #>
  [CmdletBinding()]
  param()

  # check-suppress:suppression_doc: probe whether uv is installed; throws when absent
  if (Get-Command -Name uv -ErrorAction SilentlyContinue) {
    Write-NucleusInfo "uv is already available at $(Get-Command uv | Select-Object -ExpandProperty Source)"
    return
  }

  Write-NucleusInfo "Installing uv from astral.sh..."
  $installScript = Join-Path $env:TEMP 'uv-install.ps1'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $webClient = [System.Net.WebClient]::new()
    $webClient.DownloadFile('https://astral.sh/uv/install.ps1', $installScript)
  } catch {
    throw "Failed to download uv installer: $_"
  }

  # WHY -NoModifyPath: the installer is a PowerShell script invoked with & in this
  # process, so $LASTEXITCODE stays $null and the Get-Command check below is the
  # reliable post-condition guard.
  & $installScript -NoModifyPath

  $uvDir = Join-Path $env:USERPROFILE '.local\bin'
  if ($env:PATH -notlike "*$uvDir*") {
    $env:PATH = "$uvDir;$env:PATH"
  }

  # check-suppress:suppression_doc: probe whether uv is installed; throws when absent
  if (-not (Get-Command -Name uv -ErrorAction SilentlyContinue)) {
    throw "uv installed but not found on PATH after refresh (expected at $uvDir)"
  }
  Write-NucleusInfo "uv installed successfully at $uvDir"
}

# check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
  throw "winget is required but was not found in PATH."
}

$BootstrapVersions = Import-BootstrapVersionTable -FilePath $VersionsFilePath

# WHY here rather than winget: --silent does not suppress the GpgEX regsvr32
  # dialog on headless CI, so the install hangs.
# Ref: https://github.com/fleetdm/fleet/pull/50025
$gnupgVersion = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GNUPG_VERSION"
$gnupgDate = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GNUPG_INSTALLER_DATE"
$gnupgHash = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GNUPG_INSTALLER_SHA256"
Install-GnuPGDirect -Version $gnupgVersion -InstallerDate $gnupgDate -InstallerSha256 $gnupgHash

$BootstrapPackageVersions = [ordered]@{
  "Hashicorp.Packer" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_PACKER_VERSION"
  "SecretsOPerationS.SOPS" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_SOPS_VERSION"
}

foreach ($package in $BootstrapPackageVersions.GetEnumerator()) {
  Invoke-WingetPackageInstall -Id $package.Key -Version $package.Value
}

# Provisioning: install lockfile-pinned PowerShell modules (Pester,
# PSScriptAnalyzer, powershell-yaml). Preflight in check.ps1/test.ps1 only
# asserts availability.
$moduleSetupPath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\setup\Invoke-PowerShellModuleSetup.ps1'
if (Test-Path -Path $moduleSetupPath) {
  . $moduleSetupPath
  Invoke-PowerShellModuleSetup
}

# Check pipeline tools. Same WinGet IDs as
# src/hosts/Windows/system/packages.dsc.yml; yamllint comes from uv (no WinGet
# ID).
$checkTools = @(
    'rhysd.actionlint'
    'suzuki-shunsuke.pinact'
    'mvdan.shfmt'
    'tamasfe.taplo'
    'MikeFarah.yq'
    'zizmor.zizmor'
)
foreach ($tool in $checkTools) {
    Invoke-WingetPackageInstall -Id $tool
}
# WHY: WinGet writes PATH in the registry, invisible to this and child
# processes until the terminal restarts (winget-cli#549). GITHUB_PATH is the
# only mechanism that propagates PATH additions across CI steps.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$uvToolBin = Join-Path $env:USERPROFILE '.local\bin'
if ($env:PATH -notlike "*$uvToolBin*") {
    $env:PATH = "$uvToolBin;$env:PATH"
}
# WHY before the uv tool installs below: CI runners ship no uv and it is
# required for yamllint and check-jsonschema.
Install-Uv

if ($env:GITHUB_PATH) {
    $winGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    if (Test-Path $winGetLinks) {
        Add-Content -Path $env:GITHUB_PATH -Value $winGetLinks
    }
    # Propagate uv's own binary directory so uv is available in later CI steps.
    $uvDir = Join-Path $env:LOCALAPPDATA 'uv'
    if (Test-Path $uvDir) {
        Add-Content -Path $env:GITHUB_PATH -Value $uvDir
    }
    # Propagate uv tool binary directory so tool-installed binaries
    # (yamllint, check-jsonschema) are available in subsequent CI steps.
    if (Test-Path $uvToolBin) {
        Add-Content -Path $env:GITHUB_PATH -Value $uvToolBin
    }
}
# yamllint: Python package, no WinGet ID. Requires uv on PATH.
# check-suppress:suppression_doc: probe whether uv is installed; warns when absent
if (Get-Command -Name uv -ErrorAction SilentlyContinue) {
    & uv tool install yamllint
    if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "failed to install yamllint via uv tool install"
    }
} else {
    Write-NucleusWarning "uv not found — yamllint will not be installed"
}
# check-jsonschema: Python package, no WinGet ID. Requires uv on PATH.
# check-suppress:suppression_doc: probe whether uv is installed; warns when absent
if (Get-Command -Name uv -ErrorAction SilentlyContinue) {
    & uv tool install check-jsonschema
    if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "failed to install check-jsonschema via uv tool install"
    }
} else {
    Write-NucleusWarning "uv not found — check-jsonschema will not be installed"
}

Invoke-RepositoryDirenvAllowIfAvailable

if ($Apply) {
  $applyScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\hosts\Windows\apply.ps1"
  if (-not (Test-Path -Path $applyScriptPath)) {
    throw "Apply script not found: $applyScriptPath"
  }

  # WHY an explicit ModuleDir: operators need to know which helper modules the
  # apply flow loads, so a default is added unless the caller already passed one.
  $effectiveApplyArgs = @($ApplyArgs)
  $applyArgsText = ($effectiveApplyArgs -join " ")
  if ($applyArgsText -notmatch "(?i)(^|\s)-ModuleDir(\s|$)") {
    $defaultModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "..\src\platforms\Windows\modules"
    $effectiveApplyArgs += @("-ModuleDir", $defaultModuleDir)
  }
  if ($applyArgsText -notmatch "(?i)(^|\s)-Users(\s|$)") {
    $effectiveApplyArgs += @("-Users", @($env:USERNAME))
  }

  # Cross-platform CLI parity: forward flags that apply.ps1 accepts.
  if ($NoAISync) { $effectiveApplyArgs += "-NoAISync" }
  if ($ReplicaSync) { $effectiveApplyArgs += "-ReplicaSync" }
  # TargetUser is POSIX-only (nix apply --target-user) and apply.ps1 has no such
  # parameter, so it is not forwarded.
  if ($TargetUser) {
    Write-Debug "bootstrap: -TargetUser accepted but ignored on Windows (POSIX-only)"
  }

  $healthCheckPath = Join-Path -Path $PSScriptRoot -ChildPath "health-check.ps1"
  if (Test-Path -Path $healthCheckPath) {
    & $healthCheckPath -MinFreeGB 10
    if ($LASTEXITCODE -ne 0) {
      throw "Windows pre-flight health check failed with exit code $LASTEXITCODE."
    }
  }

  Write-NucleusInfo "Running apply flow via $applyScriptPath"
  & $applyScriptPath @effectiveApplyArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Apply script exited with code $LASTEXITCODE."
  }

  return
}

Write-NucleusInfo "Bootstrap complete. Run '.\src\hosts\Windows\apply.ps1' to configure this host, or use -Apply."
