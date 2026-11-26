<#
.SYNOPSIS
  Log directory helpers and management functions for nucleus services.

.DESCRIPTION
  Log directory helpers, sanitization, and time-based expiry. Paths come from
  services.json $logging. Rotation is nucleus-logs' own, so this module holds
  none.

.NOTES
  Environment variables:
    NUCLEUS_LOG_DIR / NUCLEUS_SYSTEM_LOG_DIR override JSON paths when set.
    NUCLEUS_REPO_ROOT overrides the repo root; when unset the root is derived
    from this module's location and a missing root is a hard error.
#>

. (Join-Path $PSScriptRoot 'Get-NucleusHostPlatform.ps1')

# WHY: functions defined here run in the dot-sourcing caller's scope, where
# $PSScriptRoot names that caller's directory. Capture this module's own path
# at load time so root derivation does not depend on the caller or the ambient
# variable.
$script:InvokeLogManagementPath = $MyInvocation.MyCommand.Path

function Resolve-NucleusLogRepoRoot {
  <#
  .SYNOPSIS
    Resolves the nucleus repository root for log path helpers.
  .DESCRIPTION
    NUCLEUS_REPO_ROOT wins when set. Otherwise the resolver walks up from this
    module's own file until it finds src/flake.nix, matching the POSIX
    derive_repo_root contract. A missing root throws instead of defaulting.
  .OUTPUTS
    The repository root path.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
    return $repoRoot
  }

  $candidate = if ($script:InvokeLogManagementPath) {
    Split-Path -Parent $script:InvokeLogManagementPath
  } else {
    ''
  }
  for ($i = 0; $i -lt 6 -and -not [string]::IsNullOrWhiteSpace($candidate); $i++) {
    $marker = Join-Path -Path $candidate -ChildPath 'src' -AdditionalChildPath 'flake.nix'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
      return $candidate
    }
    $parent = Split-Path -Parent $candidate
    if ($parent -eq $candidate) { break }
    $candidate = $parent
  }
  throw 'cannot resolve nucleus repository root from NUCLEUS_REPO_ROOT or the log module location'
}

function Get-NucleusServicesJsonPath {
  $repoRoot = Resolve-NucleusLogRepoRoot
  return Join-Path -Path $repoRoot -ChildPath 'src\modules\services.json'
}

function Expand-NucleusLogPathTemplate {
  <#
  .SYNOPSIS
    Expands ~ and %ENV% templates in log path strings.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Template
  )

  if ($Template.StartsWith('~/')) {
    return Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) -ChildPath $Template.Substring(2)
  }
  if ($Template.StartsWith('~')) {
    return $Template.Replace('~', [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
  }
  return [Environment]::ExpandEnvironmentVariables($Template)
}

function Get-NucleusLoggingRootsFromJson {
  $jsonPath = Get-NucleusServicesJsonPath
  $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
  $hostKey = Get-NucleusHostKey
  return $json.'$logging'.$hostKey
}

function Get-NucleusLogDir {
  <#
  .SYNOPSIS
    Returns the user-level log directory path.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  #>
  [CmdletBinding()]
  param(
    [switch]$PassThru
  )

  if ($env:NUCLEUS_LOG_DIR) {
    $path = $env:NUCLEUS_LOG_DIR
  } else {
    $roots = Get-NucleusLoggingRootsFromJson
    $path = Expand-NucleusLogPathTemplate -Template $roots.logDir
  }

  if ($PassThru -and -not (Test-Path -LiteralPath $path -PathType Container)) {
    $null = New-Item -Path $path -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  }
  return $path
}

function Get-NucleusSystemLogDir {
  <#
  .SYNOPSIS
    Returns the system-level log directory path.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  #>
  [CmdletBinding()]
  param(
    [switch]$PassThru
  )

  if ($env:NUCLEUS_SYSTEM_LOG_DIR) {
    $path = $env:NUCLEUS_SYSTEM_LOG_DIR
  } else {
    $roots = Get-NucleusLoggingRootsFromJson
    $path = [Environment]::ExpandEnvironmentVariables($roots.systemLogDir)
  }

  if ($PassThru -and -not (Test-Path -LiteralPath $path -PathType Container)) {
    $null = New-Item -Path $path -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  }
  return $path
}

function Test-NucleusLogDirWritable {
  <#
  .SYNOPSIS
    Returns $true when the current user can write to the given log directory.
  .DESCRIPTION
    Probes writability by opening the directory for write access without mutating
    files, which is how the caller decides between inline rotation and escalation
    to the system-level scheduled task.
  .PARAMETER Path
    Directory path to probe.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

  try {
    $dirInfo = [System.IO.DirectoryInfo]::new($Path)
    $acl = $dirInfo.GetAccessControl()
    $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    foreach ($rule in $rules) {
      if ($identity.User -eq $rule.IdentityReference -or $identity.Groups -contains $rule.IdentityReference) {
        if ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write -and $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) {
          return $true
        }
      }
    }
    return $false
  } catch {
    return $false
  }
}

function ConvertTo-SanitizedText {
  <#
  .SYNOPSIS
    Strips ANSI escape sequences and control characters from text input.
  .PARAMETER InputObject
    String to sanitize. Accepts pipeline input.
  #>
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline)]
    [string]$InputObject
  )

  process {
    if ([string]::IsNullOrEmpty($InputObject)) { return }
    $sanitized = $InputObject -replace '\x1b\[[0-9;]*[a-zA-Z]', ''      # ANSI escapes
    $sanitized = $sanitized -replace '\x1b\][^\x07\x1b]*\x07', ''       # OSC sequences
    $sanitized = $sanitized -replace '\x1b[PX^_].*\x1b\\', ''           # DCS/SOS/PM/APC
    $sanitized = $sanitized -replace '\r', ''                            # carriage returns
    $sanitized = $sanitized -replace '[^\x09\x0A\x20-\x7E\x80-\xFF]', '' # control chars except tab/newline
    Write-Output $sanitized
  }
}

function ConvertFrom-NucleusExpiryDuration {
  <#
  .SYNOPSIS
    Parses duration strings like 7d or 24h into whole-day counts.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [string]$Expiry = '7d'
  )

  if ($Expiry -match '^(\d+)d$') {
    return [int]$Matches[1]
  }
  if ($Expiry -match '^(\d+)h$') {
    return [int][Math]::Ceiling([int]$Matches[1] / 24.0)
  }
  return 7
}

function Invoke-LogExpiry {
  <#
  .SYNOPSIS
    Deletes rotated archives and dated application logs older than Expiry.
  .PARAMETER Path
    Root directory to scan recursively.
  .PARAMETER Expiry
    Duration string (default 7d).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$Expiry = '7d'
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

  $days = ConvertFrom-NucleusExpiryDuration -Expiry $Expiry
  if ($days -le 0) { return }

  $cutoff = (Get-Date).AddDays(-$days)
  # WHY: the pattern must match the name.N.log archives nucleus-logs rotation
  # writes, gzipped or plain, plus a bare compressed <base>.log.gz.
  $pattern = '(\.\d+\.log(\.gz)?$|\.log\.gz$)'

  # check-suppress:suppression_doc: probe -- no expired log files may exist; pipeline handles empty result.
  Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match $pattern -and $_.LastWriteTime -lt $cutoff
  } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
  }
}
