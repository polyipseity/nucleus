<#
.SYNOPSIS
  Install bootstrap dependencies for the nucleus environment on Windows.

.DESCRIPTION
  Installs GnuPG and SOPS via winget using pinned versions from
  scripts/bootstrap-versions.env.
  Runs a pre-flight health check before invoking apply when -Apply is used.
  Use -Apply to run the Windows apply script after dependency installation.

.PARAMETER Apply
  Install dependencies, then run src/hosts/Windows/apply.ps1 (default: $false).

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
  [switch]$ReplicaSync = $(if ($env:NUCLEUS_REPLICA_SYNC -eq 'true') { $true } else { $false }),

  [Parameter()]
  [string]$TargetUser = $(if ($env:NUCLEUS_TARGET_USER) { $env:NUCLEUS_TARGET_USER } else { '' }),

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# Refuse to run as Administrator — privilege escalation is managed internally
# when needed rather than relying on an already-elevated caller.
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
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
    The settings key to look up (e.g. 'NUCLEUS_GPG4WIN_VERSION').

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

  if ($Version) {
    $versionedArgs = @($installArgs + @("--version", $Version))
    & winget @versionedArgs

    if ($LASTEXITCODE -eq 0) {
      return
    }

    if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
      Write-NucleusInfo "$($PSStyle.Foreground.Green)Package '$Id' is already installed at the requested version (or newer available version is not applicable).$($PSStyle.Reset)"
      return
    }

    Write-NucleusInfo "$($PSStyle.Foreground.Yellow)Requested version '$Version' for '$Id' not available. Falling back to latest.$($PSStyle.Reset)"
  }

  & winget @installArgs

  if ($LASTEXITCODE -eq 0) {
    return
  }

  if ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
    Write-NucleusInfo "$($PSStyle.Foreground.Green)Package '$Id' is already installed and up to date.$($PSStyle.Reset)"
    return
  }

  throw "Failed to install package '$Id' with winget. Exit code: $LASTEXITCODE"
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

$BootstrapPackageVersions = [ordered]@{
  "GnuPG.Gpg4win" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_GPG4WIN_VERSION"
  "SecretsOPerationS.SOPS" = Get-RequiredVersionSetting -Settings $BootstrapVersions -Key "NUCLEUS_SOPS_VERSION"
}

foreach ($package in $BootstrapPackageVersions.GetEnumerator()) {
  Invoke-WingetPackageInstall -Id $package.Key -Version $package.Value
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
    $defaultModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "..\src\hosts\Windows\modules"
    $effectiveApplyArgs += @("-ModuleDir", $defaultModuleDir)
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

  Write-NucleusInfo "$($PSStyle.Foreground.Cyan)Running apply flow via $applyScriptPath$($PSStyle.Reset)"
  & $applyScriptPath @effectiveApplyArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Apply script exited with code $LASTEXITCODE."
  }

  return
}

Write-NucleusInfo "$($PSStyle.Foreground.Green)Bootstrap complete. Run '.\src\hosts\Windows\apply.ps1' to configure this host, or use -Apply.$($PSStyle.Reset)"
