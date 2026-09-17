<#
.SYNOPSIS
  Install bootstrap dependencies for the nucleus environment on Windows.

.DESCRIPTION
  Installs GnuPG (directly from the NSIS installer) and SOPS via winget
  using pinned versions from scripts/bootstrap-versions.env.
  Runs a pre-flight health check before invoking apply when -Apply is used.
  Use -Apply to run the Windows apply script after dependency installation.

.PARAMETER Apply
  Install dependencies, then run src/hosts/Windows/apply.ps1 (default: $false).

.PARAMETER ForceAdmin
  Allow running as Administrator. Use in CI environments where elevation cannot
  be avoided (default: $false).

.PARAMETER ApplyArgs
  Optional arguments passed through to src/hosts/Windows/apply.ps1 (default: empty).
  Use -- before positional passthrough args (e.g., .\bootstrap.ps1 -Apply -- -DryRun).

.PARAMETER NoAISync
  Suppresses the post-apply Ollama model sync step. Forwarded to apply.ps1 as
  -NoAISync when -Apply is used (default: $false).

.PARAMETER ReplicaSync
  Run the post-apply cloud replica sync step. Forwarded to apply.ps1 as
  -ReplicaSync when -Apply is used (default: $false).

.PARAMETER TargetUser
  Accepted for cross-platform CLI parity. Only effective on the POSIX apply
  path (nix run .#apply -- --target-user=<name>). On Windows this flag is
  accepted but ignored (default: none).

.PARAMETER Help
  Show this help message and exit.

.EXAMPLE
  .\bootstrap.ps1
  Install bootstrap dependencies only.

.EXAMPLE
  .\bootstrap.ps1 -Apply
  Install dependencies, then run the apply flow.

.EXAMPLE
  .\bootstrap.ps1 -Apply -- -Help
  Install dependencies, then show help for the apply script (using -- passthrough).

.EXAMPLE
  .\bootstrap.ps1 -Apply -NoAISync
  Install dependencies and run apply, skipping AI model sync.

.NOTES
  Environment variables: NUCLEUS_APPLY, NUCLEUS_AI_SYNC, NUCLEUS_REPLICA_SYNC, NUCLEUS_TARGET_USER.
  Exit codes: 0 on success; non-zero on failure.
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

# Refuse to run as Administrator — privilege escalation is managed internally
# when needed rather than relying on an already-elevated caller.
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
    Looks up $Key in $Settings and returns its value as a trimmed string.
    Throws a descriptive error if the key is absent or its value is blank,
    preventing silent failures when a version pin is missing from the
    bootstrap-versions.env file.

  .PARAMETER Settings
    An IDictionary (typically ordered hashtable) returned by
    Import-BootstrapVersionTable.

  .PARAMETER Key
    The settings key to look up (e.g. 'NUCLEUS_GNUPG_VERSION').

  .OUTPUTS
    [string]  The non-empty value associated with $Key.
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
    Reads $FilePath line by line and extracts KEY=value pairs using the
    pattern ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$.  Comment lines (starting with
    #) and blank lines are silently skipped.  Values wrapped in single or
    double quotes have the outer quotes stripped.  Keys retain their original
    casing.

  .PARAMETER FilePath
    Absolute or relative path to the bootstrap-versions.env file.

  .OUTPUTS
    [ordered hashtable]  Parsed key/value pairs in file order.
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
    Runs `winget install` with non-interactive flags.  Handles two outcomes
    gracefully without throwing:
      - Exit code 0: package was installed or upgraded successfully.
      - Exit code -1978335189 (WINGET_ERROR_NO_APPLICABLE_UPDATE): package is
        already at the requested version or no applicable upgrade exists.

    When $Version is provided the function first attempts an exact-version
    install.  If that fails with any code other than the above two, it falls
    back to installing the latest available version.  This lets version pins
    work correctly while degrading gracefully when a specific version is
    withdrawn from the WinGet source.

  .PARAMETER Id
    WinGet package identifier (e.g. 'Git.Git').

  .PARAMETER Version
    Optional.  Exact version string to install.  When omitted, the latest
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
    # WHY: pin to community source — msstore lacks HashiCorp/SOPS packages and
    # its agreement prompt blocks source resolution on fresh CI runners.
    "--source"
    "winget"
  )

  # WHY: timeout-300s: safety net for any winget install that might hang
  # (e.g. NSIS installers that spawn resident child processes). GnuPG is
  # installed directly via Install-GnuPGDirect to avoid this class of issue.
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
    Winget's --silent flag does not suppress the GpgEX regsvr32 dialog on
    headless CI systems, causing the install to hang indefinitely. Running
    the NSIS installer directly with /S (silent) and /D=path still blocks
    on a modal MessageBox (regsvr32 gpgex6.dll failure, no /SD default).
    We poll the installer's own MainWindowHandle and close it after a grace
    period. Success is verified via the Add/Remove Programs registry entry
    (the ARP entry is written in the installer's last hidden section, so the
    exit code alone is unreliable on the timeout path).

    Ref: Fleet PR https://github.com/fleetdm/fleet/pull/50025
    Ref: Fleet commit https://github.com/fleetdm/fleet/commit/5326bed

  .PARAMETER Version
    GnuPG version string (e.g. '2.5.21').

  .PARAMETER InstallerDate
    Build date portion of the installer filename (e.g. '20260702').

  .PARAMETER InstallerSha256
    Expected SHA-256 hash of the installer EXE.
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

  # Skip if already installed at the correct version.
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

  # Create temp directory and download installer.
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

  # Verify installer hash.
  $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
  if ($actualHash -ne $InstallerSha256) {
    throw "GnuPG installer hash mismatch: expected $InstallerSha256, got $actualHash"
  }

  # Run the NSIS installer with /S (silent) and /D=path (install directory).
  # WHY: The GnuPG NSIS installer calls RegDLL on gpgex6.dll (the GpgEX shell
  # extension). On headless CI, regsvr32 fails and spawns a modal MessageBox
  # with no /SD default — the /S flag does NOT suppress these. The dialog
  # window belongs to the installer process itself, not to regsvr32/gpgex
  # children (Fleet confirmed via 5326bed). We poll the installer's own
  # MainWindowHandle and close it after a grace period so the install can
  # continue to the ARP registry entry (written in the last hidden section).
  # Success is verified via the ARP entry, not the exit code, because a
  # killed installer (timeout path) has a meaningless exit code.
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

    # After grace period, close any window the installer owns.
    # The dialog is on the installer process itself, not on child processes.
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

  # Kill resident daemon processes spawned by the installer.
  # Leaving them running holds file locks that make later gpg operations fail.
  $daemons = @('gpg-agent', 'dirmngr', 'keyboxd', 'scdaemon', 'gpg-connect-agent', 'gpgme-w32spawn', 'gpa', 'launch-gpa')
  foreach ($daemon in $daemons) {
    # check-suppress:suppression_doc: daemon may not be running; best-effort stop
    Stop-Process -Name $daemon -Force -ErrorAction SilentlyContinue
  }

  # Success = ARP entry exists. The exit code is unreliable on the timeout path
  # (killed installer) and inst.nsi writes the ARP entry in its last hidden
  # section — so the entry is the canonical signal that the install completed.
  $arpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $arpKey32 = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $arpKeyUser = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  # check-suppress:suppression_doc: registry keys may not exist on all systems; probe is best-effort
  $registered = $null -ne (Get-ChildItem -Path @($arpKey, $arpKey32, $arpKeyUser) -ErrorAction SilentlyContinue |
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
    bootstrap repository root basename is exactly `nucleus`. This keeps auto-allow
    scope intentionally narrow and avoids trusting non-nucleus checkouts.

    Failures are warnings (non-fatal) because direnv allow is convenience-only
    and must not block dependency bootstrap or apply.
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
    Downloads and runs the official uv installer from astral.sh. uv is
    required for installing Python-based check tools (yamllint,
    check-jsonschema) that have no WinGet or Scoop package. The installer
    places uv.exe in $env:LOCALAPPDATA\uv; this function refreshes PATH
    and propagates the directory to GITHUB_PATH for subsequent CI steps.
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

  # WHY: -NoModifyPath prevents the installer from modifying shell profiles.
  # The uv installer is a PowerShell script invoked via & in the same process.
  # $LASTEXITCODE is only set by native/external commands (.exe, .bat), not by
  # PowerShell scripts, so it remains $null here regardless of outcome. The
  # Get-Command check below is the reliable post-condition guard.
  & $installScript -NoModifyPath

  # WHY: The uv installer places binaries in ~/.local/bin, not %LOCALAPPDATA%\uv.
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

# GnuPG requires direct NSIS installation — winget's --silent flag does not
# suppress the GpgEX regsvr32 dialog on headless CI, causing a hang.
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

# Provisioning: install lockfile-pinned PowerShell modules (Pester, PSScriptAnalyzer,
# powershell-yaml). Preflight in check.ps1/test.ps1 only asserts availability.
$moduleSetupPath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\setup\Invoke-PowerShellModuleSetup.ps1'
if (Test-Path -Path $moduleSetupPath) {
  . $moduleSetupPath
  Invoke-PowerShellModuleSetup
}

# Provision check pipeline tools (actionlint, pinact, shfmt, taplo, yq, zizmor).
# Same WinGet IDs as src/hosts/Windows/system/packages.dsc.yml.
# yamllint is installed separately via uv (no WinGet ID).
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
# Refresh PATH from registry so newly installed tools are available in the
# current process. In GitHub Actions, also propagate the WinGet Links directory
# and the uv tool bin directory to $env:GITHUB_PATH so subsequent steps can
# find WinGet-installed and uv-installed binaries.
# WHY: WinGet modifies PATH in the registry but the change is invisible to the
# current and child processes until the terminal restarts (winget-cli#549).
# uv tool install places binaries in ~\.local\bin; GITHUB_PATH is the only
# mechanism to propagate PATH additions across GitHub Actions steps.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$uvToolBin = Join-Path $env:USERPROFILE '.local\bin'
if ($env:PATH -notlike "*$uvToolBin*") {
    $env:PATH = "$uvToolBin;$env:PATH"
}
# Install uv before attempting uv tool installs. uv is not pre-installed on
# GitHub Actions Windows runners and is required for yamllint and
# check-jsonschema (no WinGet or Scoop packages exist for these).
Install-Uv

if ($env:GITHUB_PATH) {
    $winGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    if (Test-Path $winGetLinks) {
        Add-Content -Path $env:GITHUB_PATH -Value $winGetLinks
    }
    # Propagate uv's own binary directory so uv is available in subsequent
    # CI steps (each step runs in a fresh process).
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

  # Windows apply requires an explicit module path so operators are aware of
  # which helper modules will be loaded. Add a default here unless the caller
  # already provided an explicit override in -ApplyArgs.
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
  # TargetUser is POSIX-only (nix apply --target-user); accepted but not
  # forwarded on Windows since apply.ps1 does not implement this param.
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
