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
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
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
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
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
    the NSIS installer directly with /S (silent) and /D=path skips the
    dialog. Resident daemon processes spawned by the installer are killed
    after installation completes.

    Ref: https://github.com/fleetdm/fleet/pull/50025

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
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
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
  # WHY: /S suppresses all UI dialogs including the GpgEX regsvr32 dialog
  # that blocks on headless CI. /D= must be the last argument per NSIS spec.
  Write-NucleusInfo "Installing GnuPG $Version to $installDir"
  $proc = Start-Process -FilePath $installerPath -ArgumentList "/S", "/D=$installDir" `n    -PassThru -NoNewWindow
  $TimeoutSeconds = 300
  if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} # check-suppress:suppression_doc: process may already have exited; -ErrorAction SilentlyContinue handles the common case
    throw "GnuPG installer timed out after $TimeoutSeconds seconds"
  }

  if ($proc.ExitCode -ne 0) {
    throw "GnuPG installer exited with code $($proc.ExitCode)"
  }

  # Kill resident daemon processes spawned by the installer.
  # These prevent WaitForExit from returning when winget manages the process.
  # With direct invocation they exit after /S completes, but kill them anyway
  # to avoid port/lock conflicts with later gpg operations.
  $daemons = @('gpg-agent', 'dirmngr', 'keyboxd', 'scdaemon', 'gpg-connect-agent', 'gpgme-w32spawn')
  foreach ($daemon in $daemons) {
    Stop-Process -Name $daemon -Force -ErrorAction SilentlyContinue
  }

  # Verify installation.
  if (-not (Test-Path -Path $gpgExe -PathType Leaf)) {
    throw "GnuPG installer completed but gpg.exe not found at $gpgExe"
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
  "HashiCorp.Packer" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_PACKER_VERSION"
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

# Provision check pipeline tools (actionlint, pinact, shfmt, taplo, zizmor).
# Same WinGet IDs as src/hosts/Windows/system/packages.dsc.yml.
# yamllint is installed separately via uv (no WinGet ID).
$checkTools = @(
    'rhysd.actionlint'
    'suzuki-shunsuke.pinact'
    'mvdan.shfmt'
    'tamasfe.taplo'
    'zizmor.zizmor'
)
foreach ($tool in $checkTools) {
    Invoke-WingetPackageInstall -Id $tool
}
# yamllint: Python package, no WinGet ID. Requires uv on PATH.
if (Get-Command -Name uv -ErrorAction SilentlyContinue) {
    & uv tool install yamllint
    if ($LASTEXITCODE -ne 0) {
        Write-NucleusWarning "failed to install yamllint via uv tool install"
    }
} else {
    Write-NucleusWarning "uv not found — yamllint will not be installed"
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
