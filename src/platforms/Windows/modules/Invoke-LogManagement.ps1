<#
.SYNOPSIS
  Log directory helpers and management functions for nucleus services.

.DESCRIPTION
  Provides functions for log paths, sanitization, rotation (copy-truncate), and
  time-based expiry. Paths are read from services.json $logging for Windows.

.NOTES
  Environment variables:
    NUCLEUS_LOG_DIR / NUCLEUS_SYSTEM_LOG_DIR override JSON paths when set.
    NUCLEUS_REPO_ROOT required for JSON path resolution.
  Exit codes:
    0 on success; 1 on error.
#>

. (Join-Path $PSScriptRoot 'Get-NucleusHostPlatform.ps1')

function Get-NucleusServicesJsonPath {
  $repoRoot = $env:NUCLEUS_REPO_ROOT
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'NUCLEUS_REPO_ROOT not set'
  }
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
    return Join-Path -Path $env:USERPROFILE -ChildPath $Template.Substring(2)
  }
  if ($Template.StartsWith('~')) {
    return $Template.Replace('~', $env:USERPROFILE)
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
  .DESCRIPTION
    Reads logDir from services.json $logging for Windows. Creates the directory
    when -PassThru is specified.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  .EXAMPLE
    Get-NucleusLogDir
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
  .DESCRIPTION
    Reads systemLogDir from services.json $logging for Windows. Creates the
    directory when -PassThru is specified.
  .PARAMETER PassThru
    When specified, creates the directory and returns the path.
  .EXAMPLE
    Get-NucleusSystemLogDir
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

function ConvertTo-SanitizedText {
  <#
  .SYNOPSIS
    Strips ANSI escape sequences and control characters from text input.
  .DESCRIPTION
    Reads text from the pipeline or a file and removes ANSI escape sequences
    (colors, cursor movement, OSC sequences), carriage returns, and ASCII
    control characters (except tab and newline).
  .PARAMETER InputObject
    String to sanitize. Accepts pipeline input.
  .EXAMPLE
    "hello\x1b[31mworld" | ConvertTo-SanitizedText
  .EXAMPLE
    Get-Content -Path log.txt | ConvertTo-SanitizedText
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
  $pattern = '(\.log\.\d+(\.gz)?$|^log_.*\.log$|\.log\.gz$)'

  Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match $pattern -and $_.LastWriteTime -lt $cutoff
  } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
  }
}

function Invoke-LogRotation {
  <#
  .SYNOPSIS
    Rotates log files in a directory tree based on size.
  .DESCRIPTION
    Recursively scans for *.log files. When a file exceeds MaxSize, copy-truncate
    rotation preserves the inode (POSIX parity). Archives shift .1 through MaxFiles.
  .PARAMETER Path
    Root directory containing log files to rotate.
  .PARAMETER MaxSize
    Maximum file size in bytes before rotation (default: 10 MB).
  .PARAMETER MaxFiles
    Number of rotated archives to keep (default: 4).
  .PARAMETER Compress
    Whether to compress rotated archives with gzip (default: $true).
  .EXAMPLE
    Invoke-LogRotation -Path "$env:LOCALAPPDATA\nucleus\logs\discord-music-rpc"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [int]$MaxSize = 10000000, # bytes
    [int]$MaxFiles = 4,
    [bool]$Compress = $true
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

  $logFiles = Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue
  foreach ($file in $logFiles) {
    if ($file.Length -le $MaxSize) { continue }

    $isWritable = $false
    try {
      $writeStream = [System.IO.File]::OpenWrite($file.FullName)
      $writeStream.Close()
      $isWritable = $true
    } catch {
      $isWritable = $false
    }
    if (-not $isWritable) {
      Write-Warning "log-rotation: skipping unwritable '$($file.FullName)'"
      continue
    }

    $baseName = $file.BaseName
    $dir = $file.DirectoryName

    # Remove the oldest archive if at max
    $oldest = $MaxFiles
    $oldestPath = Join-Path -Path $dir -ChildPath "$baseName.$oldest.log"
    if (Test-Path -LiteralPath $oldestPath -PathType Leaf) {
      Remove-Item -LiteralPath $oldestPath -Force
    }
    if ($Compress) {
      $oldestGz = "$oldestPath.gz"
      if (Test-Path -LiteralPath $oldestGz -PathType Leaf) {
        Remove-Item -LiteralPath $oldestGz -Force
      }
    }

    # Shift existing archives: N → N+1
    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
      $src = Join-Path -Path $dir -ChildPath "$baseName.$i.log"
      $dst = Join-Path -Path $dir -ChildPath "$baseName.$($i + 1).log"
      if (Test-Path -LiteralPath $src -PathType Leaf) {
        Move-Item -LiteralPath $src -Destination $dst -Force
      }
      if ($Compress) {
        $srcGz = "$src.gz"
        $dstGz = "$dst.gz"
        if (Test-Path -LiteralPath $srcGz -PathType Leaf) {
          Move-Item -LiteralPath $srcGz -Destination $dstGz -Force
        }
      }
    }

    # Copy-truncate: copy to .1.log, then truncate in-place
    $archivePath = Join-Path -Path $dir -ChildPath "$baseName.1.log"
    Copy-Item -LiteralPath $file.FullName -Destination $archivePath -Force
    $truncateStream = [System.IO.File]::Open(
      $file.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Write
    )
    $truncateStream.SetLength(0)
    $truncateStream.Close()

    if ($Compress) {
      $null = & gzip @($archivePath) 2>$null  # check-suppress:suppression_doc: archive may fail to compress if already corrupted or missing; $? checked below
      if (-not $?) {
        Write-Warning "log-rotation: gzip failed for $archivePath; keeping uncompressed."
      }
    }
  }
}
